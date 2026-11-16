# Swaps an existing WhatsApp inbox onto a new Dualhook connection key (and
# optionally new Meta ids) in place, marks it externally managed and clears the
# reauthorization flag. Never destroys the inbox or channel.
class Coro::InboxRekeyer
  def initialize(inbox_id:, api_key:, dry_run:, phone_number_id: nil, waba_id: nil)
    @inbox = Inbox.find(inbox_id)
    @api_key = api_key
    @dry_run = dry_run
    @phone_number_id = phone_number_id.to_s.strip.presence
    @waba_id = waba_id.to_s.strip.presence
  end

  def perform
    channel = Coro::Provisioning.whatsapp_cloud_channel!(@inbox)
    Coro::Provisioning.check_dualhook_key!(@api_key)
    before = channel.provider_config
    config = new_config(before)
    was_reauth = channel.reauthorization_required?
    apply(channel, config) unless @dry_run

    {
      dry_run: @dry_run, inbox_id: @inbox.id, account_id: @inbox.account_id, channel_id: channel.id, phone_number: channel.phone_number,
      phone_number_id: config['phone_number_id'], business_account_id: config['business_account_id'], externally_managed: true,
      previous_api_key: Coro::Provisioning.key_fingerprint(before['api_key']), api_key: Coro::Provisioning.key_fingerprint(@api_key),
      reauthorization_required_before: was_reauth, reauthorization_required_after: channel.reauthorization_required?
    }
  end

  private

  def new_config(before)
    config = before.merge(
      'api_key' => @api_key,
      'phone_number_id' => (@phone_number_id || before['phone_number_id']).to_s,
      'business_account_id' => (@waba_id || before['business_account_id']).to_s,
      'externally_managed' => true
    )
    missing = Coro::Provisioning.missing_keys(config)
    raise Coro::Provisioning::Error, "missing #{missing.join(', ')}; pass them as task args" if missing.any?

    config
  end

  # update! (not destroy/recreate): only after_update callbacks run, none of which touch Meta.
  def apply(channel, config)
    channel.update!(provider_config: config)
    channel.reauthorized!
  end
end
