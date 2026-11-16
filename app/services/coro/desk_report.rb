# Read-only health report for a brand desk (account + WhatsApp inbox). Never prints key values.
class Coro::DeskReport
  def initialize(account_id:, inbox_id:)
    @account = Account.find(account_id)
    @inbox = @account.inboxes.find(inbox_id)
  end

  def perform
    member_ids = @inbox.inbox_members.pluck(:user_id)
    {
      account_id: @account.id, account_name: @account.name, inbox_id: @inbox.id, inbox_name: @inbox.name,
      channel_type: @inbox.channel_type, account_users: account_users, inbox_members_count: member_ids.size,
      account_users_missing_from_inbox: @account.account_users.pluck(:user_id) - member_ids,
      enable_auto_assignment: @inbox.enable_auto_assignment, conversations_count: @inbox.conversations.count
    }.merge(channel_report)
  end

  private

  def account_users
    @account.account_users.includes(:user).order(:id).map { |au| { user_id: au.user_id, email: au.user&.email, role: au.role } }
  end

  def channel_report
    channel = @inbox.channel
    reauth = channel.respond_to?(:reauthorization_required?) ? channel.reauthorization_required? : nil
    return { reauthorization_required: reauth } unless channel.is_a?(Channel::Whatsapp)

    config = channel.provider_config
    {
      phone_number: channel.phone_number, provider: channel.provider, externally_managed: channel.externally_managed?,
      provider_config_keys: config.keys.sort, missing_keys: Coro::Provisioning.missing_keys(config),
      api_key: Coro::Provisioning.key_fingerprint(config['api_key'])&.except(:sha256_8),
      dualhook_key: Whatsapp::CloudApiHost.dualhook_key?(config['api_key']), reauthorization_required: reauth
    }
  end
end
