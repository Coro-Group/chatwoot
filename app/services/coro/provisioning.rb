# Shared helpers for the Coro Inbox provisioning services (lib/tasks/coro_provisioning.rake).
# Every service is idempotent, honours dry_run, and returns a JSON-serialisable Hash.
# API keys are never returned — only a fingerprint.
module Coro::Provisioning
  class Error < StandardError; end

  REQUIRED_KEYS = %w[api_key phone_number_id business_account_id].freeze

  module_function

  # First 8 chars (e.g. "dh_live_") + length + short sha256. Short keys only show 2 chars so the
  # prefix can never reveal most of a key.
  def key_fingerprint(api_key)
    return nil if api_key.blank?

    key = api_key.to_s
    { prefix: key[0, key.length >= 20 ? 8 : 2], length: key.length, sha256_8: Digest::SHA256.hexdigest(key)[0, 8] }
  end

  def check_dualhook_key!(api_key)
    raise Error, 'CORO_LINE_API_KEY is required' if api_key.blank?
    return if Whatsapp::CloudApiHost.dualhook_key?(api_key) || ENV.fetch('ALLOW_NON_DUALHOOK_KEY', nil) == '1'

    raise Error, 'CORO_LINE_API_KEY is not a Dualhook key (dh_live_/dh_test_); set ALLOW_NON_DUALHOOK_KEY=1 to override'
  end

  def whatsapp_cloud_channel!(inbox)
    channel = inbox.channel
    raise Error, "inbox #{inbox.id} is #{inbox.channel_type}, not WhatsApp" unless channel.is_a?(Channel::Whatsapp)
    raise Error, "inbox #{inbox.id} provider is #{channel.provider}, not whatsapp_cloud" unless channel.provider == 'whatsapp_cloud'

    channel
  end

  def missing_keys(config)
    REQUIRED_KEYS.select { |key| config[key].blank? }
  end

  # Inbox-level flag gates both assignment v1 (AutoAssignmentHandler) and v2 (AutoAssignment::AssignmentService).
  def disable_auto_assignment(inboxes, dry_run)
    inboxes.where(enable_auto_assignment: true).order(:id).map do |inbox|
      inbox.update!(enable_auto_assignment: false) unless dry_run
      inbox.id
    end
  end

  def add_inbox_members(account, inbox, dry_run)
    existing = inbox ? inbox.inbox_members.pluck(:user_id) : []
    to_add = account.account_users.order(:id).pluck(:user_id) - existing
    to_add.each { |user_id| inbox.inbox_members.create!(user_id: user_id) } unless dry_run
    { added_user_ids: to_add, already_members: existing.size }
  end
end
