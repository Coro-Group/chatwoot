# One-off: flags existing WhatsApp inboxes as externally managed. Only adds the
# flag (update_columns: no validation round-trip, no callbacks) and reports
# anything that looks off; it never changes keys or Meta config.
class Coro::ExternallyManagedMarker
  def initialize(inbox_ids:, dry_run:)
    @inbox_ids = inbox_ids
    @dry_run = dry_run
  end

  def perform
    @inbox_ids.map { |inbox_id| mark(inbox_id) }
  end

  private

  def mark(inbox_id)
    inbox = Inbox.find_by(id: inbox_id)
    return { inbox_id: inbox_id, error: 'not found' } if inbox.nil?
    return { inbox_id: inbox.id, error: "channel is #{inbox.channel_type}" } unless inbox.channel.is_a?(Channel::Whatsapp)

    channel = inbox.channel
    already = channel.externally_managed?
    flag!(channel) unless @dry_run || already
    report(inbox, channel, already)
  end

  def flag!(channel)
    channel.update_columns(provider_config: channel.provider_config.merge('externally_managed' => true), updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def report(inbox, channel, already)
    config = channel.provider_config
    { inbox_id: inbox.id, account_id: inbox.account_id, phone_number: channel.phone_number, provider: channel.provider,
      already_externally_managed: already, changed: !already && !@dry_run,
      missing_keys: Coro::Provisioning.missing_keys(config), source: config['source'],
      dualhook_key: Whatsapp::CloudApiHost.dualhook_key?(config['api_key']) }
  end
end
