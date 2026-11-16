# == Schema Information
#
# Table name: channel_whatsapp
#
#  id                             :bigint           not null, primary key
#  message_templates              :jsonb
#  message_templates_last_updated :datetime
#  phone_number                   :string           not null
#  provider                       :string           default("default")
#  provider_config                :jsonb
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  account_id                     :integer          not null
#
# Indexes
#
#  index_channel_whatsapp_on_phone_number  (phone_number) UNIQUE
#

class Channel::Whatsapp < ApplicationRecord
  include Channelable
  include Reauthorizable

  self.table_name = 'channel_whatsapp'
  EDITABLE_ATTRS = [:phone_number, :provider, { provider_config: {} }].freeze

  # default at the moment is 360dialog lets change later.
  PROVIDERS = %w[default whatsapp_cloud].freeze
  before_validation :ensure_webhook_verify_token
  before_validation :preserve_externally_managed_flag, on: :update

  validates :provider, inclusion: { in: PROVIDERS }
  validates :phone_number, presence: true, uniqueness: true
  validate :validate_provider_config

  after_create :sync_templates, unless: :skip_template_sync_on_create?
  after_update_commit :log_credentials_transfer, if: :saved_change_to_provider_config?
  before_destroy :teardown_webhooks
  after_commit :setup_webhooks, on: :create, if: :should_auto_setup_webhooks?

  def name
    'Whatsapp'
  end

  # Mirrors Channel::TwilioSms#voice_enabled? so the call subsystem can duck-type across providers.
  # Meta's Calling API is available to any whatsapp_cloud inbox (embedded-signup or manual keys);
  # only 360dialog (default provider) can't reach the call APIs.
  def voice_enabled?
    voice_calling_supported? &&
      provider_config['calling_enabled'].present? &&
      account.feature_enabled?('channel_voice')
  end

  # Mutes only the incoming side of calling; default on, so only an explicit false disables inbound.
  def inbound_calls_enabled?
    provider_config['inbound_calls_enabled'] != false
  end

  # Whether this inbox can do WhatsApp calling at all. Meta's Calling API is
  # reachable by any whatsapp_cloud inbox, so 360dialog inboxes can't be toggled
  # on even though calling_enabled would persist.
  def voice_calling_supported?
    provider == 'whatsapp_cloud'
  end

  # Coro: lines whose Meta webhook (WABA-level override) is owned by an external
  # router (company-chat via Dualhook) and forwarded into this inbox. Chatwoot must
  # never register, override, subscribe or tear down Meta webhooks for these, and
  # background jobs must not rewrite their credentials.
  def externally_managed?
    ActiveModel::Type::Boolean.new.cast(provider_config&.dig('externally_managed')) == true
  end

  def provider_service
    if provider == 'whatsapp_cloud'
      Whatsapp::Providers::WhatsappCloudService.new(whatsapp_channel: self)
    else
      Whatsapp::Providers::Whatsapp360DialogService.new(whatsapp_channel: self)
    end
  end

  # Enables voice: turns calling on at Meta (idempotent), then re-registers webhooks
  # with the in-memory calling_enabled flag so the `calls` field is subscribed. The
  # flag is persisted only after registration succeeds, so a webhook failure can't
  # leave the inbox reporting voice_enabled? while the WABA isn't subscribed to calls.
  # Saved with validate: false to skip validate_provider_config's remote credential
  # re-check, which could spuriously fail and desync the flag from Meta.
  def enable_voice_calling!
    raise 'WhatsApp calling requires a whatsapp_cloud inbox' unless voice_calling_supported?
    raise 'WhatsApp calling requires the channel_voice feature' unless account.feature_enabled?('channel_voice')
    raise 'WhatsApp calling cannot be toggled on an externally managed inbox' if externally_managed?

    provider_service.update_calling_status('ENABLED')
    self.provider_config = provider_config.merge('calling_enabled' => true)
    webhook_setup_service.register_callback
    save!(validate: false)
  end

  # Disables voice: unsets calling_enabled (gates the call subsystem) and re-registers
  # webhooks, which drops `calls` from the subscription (best-effort, so a Meta outage
  # can't trap admins). Leaves Meta's WABA calling.status untouched.
  def disable_voice_calling!
    raise 'WhatsApp calling requires a whatsapp_cloud inbox' unless voice_calling_supported?

    self.provider_config = provider_config.merge('calling_enabled' => false)
    save!(validate: false)
    return if externally_managed?

    begin
      webhook_setup_service.register_callback
    rescue StandardError => e
      Rails.logger.warn "[WHATSAPP CALL] disable webhook re-subscribe failed: #{e.message}"
    end
  end

  # Whether the pending (unsaved) provider_config change drops the embedded_signup
  # source marker, i.e. this save is an embedded signup → manual setup transfer.
  def embedded_to_manual_transfer_pending?
    before, after = provider_config_change
    before&.dig('source') == 'embedded_signup' && after['source'] != 'embedded_signup'
  end

  def mark_message_templates_updated
    # rubocop:disable Rails/SkipsModelValidations
    update_column(:message_templates_last_updated, Time.zone.now)
    # rubocop:enable Rails/SkipsModelValidations
  end

  delegate :send_message, to: :provider_service
  delegate :send_template, to: :provider_service
  delegate :sync_templates, to: :provider_service
  delegate :media_url, to: :provider_service
  delegate :api_headers, to: :provider_service

  def setup_webhooks
    if externally_managed?
      Rails.logger.info "[WHATSAPP] Skipping webhook setup for externally managed channel #{id}"
      return
    end

    perform_webhook_setup
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Webhook setup failed: #{e.message}"
    prompt_reauthorization!
  end

  private

  def ensure_webhook_verify_token
    provider_config['webhook_verify_token'] ||= SecureRandom.hex(16) if provider == 'whatsapp_cloud'
  end

  # The dashboard inbox settings form posts provider_config wholesale without this
  # key; don't let an ordinary settings save silently drop the external-routing guard.
  # An explicit `externally_managed: false` still turns it off.
  def preserve_externally_managed_flag
    return unless provider_config_changed?

    previous = provider_config_was || {}
    return unless previous['externally_managed'] == true && !provider_config.key?('externally_managed')

    self.provider_config = provider_config.merge('externally_managed' => true)
  end

  def validate_provider_config
    return validate_externally_managed_config if externally_managed?

    errors.add(:provider_config, 'Invalid Credentials') unless provider_service.validate_provider_config?
  end

  # Logs only the embedded signup → manual migration (the save drops the
  # embedded_signup source marker), so credential rotations on inboxes that are
  # already manual stay silent.
  def log_credentials_transfer
    before, after = saved_change_to_provider_config
    return unless before&.dig('source') == 'embedded_signup' && after['source'] != 'embedded_signup'

    Rails.logger.info("[WHATSAPP_EMBEDDED_TO_MANUAL] success account_id=#{account_id} channel_id=#{id}")
  end

  def perform_webhook_setup
    webhook_setup_service.perform
  end

  def webhook_setup_service
    Whatsapp::WebhookSetupService.new(self, provider_config['business_account_id'], provider_config['api_key'])
  end

  # Externally managed lines are validated offline: the key belongs to the external
  # router, so no Graph/Dualhook round-trip happens on save (provisioning stays
  # network-free and idempotent).
  def validate_externally_managed_config
    %w[api_key phone_number_id business_account_id].each do |key|
      errors.add(:provider_config, "#{key} is required") if provider_config[key].blank?
    end
  end

  # Template sync on create is fine for Dualhook keys (api.dualhook.com, Bearer).
  # An externally managed inbox with any other key would hit graph.facebook.com,
  # so leave it to the scheduled sync instead of doing it inline on create.
  def skip_template_sync_on_create?
    externally_managed? && !Whatsapp::CloudApiHost.dualhook_host?(provider_config['api_key'])
  end

  def teardown_webhooks
    return if externally_managed?

    Whatsapp::WebhookTeardownService.new(self).perform
  end

  def should_auto_setup_webhooks?
    # Only auto-setup webhooks for whatsapp_cloud provider with manual setup
    # Embedded signup calls setup_webhooks explicitly in EmbeddedSignupService
    provider == 'whatsapp_cloud' && provider_config['source'] != 'embedded_signup' && !externally_managed?
  end
end
