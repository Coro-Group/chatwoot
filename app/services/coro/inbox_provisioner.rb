# Creates (or updates in place) an externally managed whatsapp_cloud inbox for a
# Dualhook coexistence line. Never destroys anything. Creation makes no Graph
# calls: externally_managed skips webhook setup and validates offline; the only
# network call is the template sync via api.dualhook.com for dh_ keys.
class Coro::InboxProvisioner
  E164 = /\A\+[1-9]\d{7,14}\z/

  # line: { inbox_name:, phone_e164:, phone_number_id:, waba_id: }
  def initialize(account_id:, line:, api_key:, dry_run:)
    @account = Account.find(account_id)
    @line = line.transform_values { |value| value.to_s.strip }
    @api_key = api_key
    @dry_run = dry_run
  end

  def perform
    validate_args!
    channel = existing_channel
    action = channel ? 'updated' : 'created'
    channel, inbox = save_line(channel) unless @dry_run
    inbox ||= channel&.inbox

    {
      dry_run: @dry_run, action: action, account_id: @account.id, inbox_id: inbox&.id, channel_id: channel&.id,
      inbox_name: @line[:inbox_name], phone_number: @line[:phone_e164], phone_number_id: @line[:phone_number_id],
      business_account_id: @line[:waba_id], externally_managed: true, enable_auto_assignment: false,
      api_key: Coro::Provisioning.key_fingerprint(@api_key),
      inbox_members: Coro::Provisioning.add_inbox_members(@account, inbox, @dry_run)
    }
  end

  private

  def validate_args!
    error = Coro::Provisioning::Error
    raise error, 'inbox_name is required' if @line[:inbox_name].blank?
    raise error, "phone must be E.164 like +971500000000, got #{@line[:phone_e164].inspect}" unless @line[:phone_e164].match?(E164)
    raise error, 'phone_number_id must be numeric' unless @line[:phone_number_id].match?(/\A\d+\z/)
    raise error, 'waba_id must be numeric' unless @line[:waba_id].match?(/\A\d+\z/)

    Coro::Provisioning.check_dualhook_key!(@api_key)
  end

  # phone_number is globally unique across accounts.
  def existing_channel
    channel = Channel::Whatsapp.find_by(phone_number: @line[:phone_e164])
    return if channel.nil?

    if channel.account_id != @account.id
      raise Coro::Provisioning::Error,
            "#{@line[:phone_e164]} already belongs to account #{channel.account_id} (inbox #{channel.inbox&.id}); refusing"
    end
    return channel if channel.provider == 'whatsapp_cloud'

    raise Coro::Provisioning::Error, "#{@line[:phone_e164]} exists with provider #{channel.provider}; refusing"
  end

  def line_config
    { 'api_key' => @api_key, 'phone_number_id' => @line[:phone_number_id],
      'business_account_id' => @line[:waba_id], 'externally_managed' => true }
  end

  def save_line(channel)
    inbox = nil
    ActiveRecord::Base.transaction do
      if channel
        channel.update!(provider_config: channel.provider_config.merge(line_config))
      else
        channel = Channel::Whatsapp.create!(account: @account, phone_number: @line[:phone_e164], provider: 'whatsapp_cloud',
                                            provider_config: line_config)
      end
      inbox = channel.inbox || @account.inboxes.create!(channel: channel, name: @line[:inbox_name])
      inbox.update!(name: @line[:inbox_name], enable_auto_assignment: false)
    end
    channel.reauthorized!
    [channel, inbox]
  end
end
