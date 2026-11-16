# Wipes an inbox's history so a line can be re-imported from scratch, keeping the
# Inbox and its Channel::Whatsapp record (destroying a channel can tear down Meta
# webhooks, and the desk/team config lives on the inbox).
#
# Safety:
# - Only deletes when execute: true (the rake task requires CONFIRM=<inbox_id> and no DRY_RUN=1);
#   otherwise it only reports counts.
# - Writes a gzipped JSONL backup before deleting anything.
# - Uses delete_all only: no model callbacks, no jobs, no notifications, nothing sent.
# - Contacts are deleted only if they were linked to this inbox, belong to its account
#   and have no contact_inboxes left anywhere after the wipe.
# - ActiveStorage blobs are left in place (the backup records their keys).
class Coro::InboxWiper
  BATCH = 1000

  # Tables keyed by conversation_id that exist only for a conversation.
  CONVERSATION_TABLES = %w[mentions conversation_participants csat_survey_responses reporting_events applied_slas sla_events calls
                           captain_faq_observations captain_message_reports].freeze
  MESSAGE_FIELDS = %w[id conversation_id source_id content content_type content_attributes message_type sender_type sender_id
                      status private created_at updated_at additional_attributes external_source_ids].freeze

  def initialize(inbox_id:, execute:, backup_dir: nil)
    @inbox = Inbox.find(inbox_id)
    @execute = execute
    @backup_dir = backup_dir.presence || Rails.root.join('tmp').to_s
  end

  def perform
    contact_ids = orphan_contact_ids
    result = { inbox_id: @inbox.id, account_id: @inbox.account_id, inbox_name: @inbox.name, executed: @execute,
               counts: counts(contact_ids) }
    return result.merge(note: dry_run_note) unless @execute

    result[:backup] = write_backup(contact_ids)
    result[:deleted] = wipe!(contact_ids)
    result.merge(inbox_preserved: Inbox.exists?(@inbox.id), channel_preserved: @inbox.channel.class.exists?(@inbox.channel_id))
  end

  private

  def dry_run_note
    "dry run: nothing deleted. Re-run with CONFIRM=#{@inbox.id} and without DRY_RUN=1 to wipe."
  end

  def conversations = Conversation.where(inbox_id: @inbox.id)
  def messages = Message.where(inbox_id: @inbox.id)
  def contact_inboxes = ContactInbox.where(inbox_id: @inbox.id)

  # Contacts of this account linked to this inbox and to no other inbox.
  def orphan_contact_ids
    linked = contact_inboxes.select(:contact_id)
    elsewhere = ContactInbox.where.not(inbox_id: @inbox.id).where(contact_id: linked).where.not(contact_id: nil).select(:contact_id)
    Contact.where(account_id: @inbox.account_id, id: linked).where.not(id: elsewhere).pluck(:id)
  end

  def counts(contact_ids)
    { conversations: conversations.count, messages: messages.count, attachments: Attachment.where(message_id: messages.select(:id)).count,
      contact_inboxes: contact_inboxes.count, contacts_only_in_this_inbox: contact_ids.size }
  end

  # ---- backup -------------------------------------------------------------

  def write_backup(contact_ids)
    FileUtils.mkdir_p(@backup_dir)
    path = File.join(@backup_dir, "coro-inbox-#{@inbox.id}-wipe-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.jsonl.gz")
    rows = Hash.new(0)
    Zlib::GzipWriter.open(path) do |gz|
      emit = lambda do |type, data|
        gz.puts({ type: type, data: data }.to_json)
        rows[type] += 1
      end
      emit.call('meta', backup_meta)
      backup_records(emit, contact_ids)
    end
    { path: path, bytes: File.size(path), rows: rows }
  end

  def backup_meta
    channel = @inbox.channel
    { inbox_id: @inbox.id, account_id: @inbox.account_id, inbox_name: @inbox.name, channel_type: @inbox.channel_type,
      phone_number: channel.try(:phone_number), exported_at: Time.current.utc.iso8601 }
  end

  def backup_records(emit, contact_ids)
    conversations.find_each { |record| emit.call('conversation', record.attributes) }
    messages.select(MESSAGE_FIELDS).find_each { |record| emit.call('message', record.attributes) }
    backup_attachments(emit)
    contact_inboxes.find_each { |record| emit.call('contact_inbox', record.attributes) }
    Contact.where(id: contact_ids).find_each { |record| emit.call('contact', record.attributes) }
  end

  def backup_attachments(emit)
    Attachment.where(message_id: messages.select(:id)).includes(file_attachment: :blob).find_each do |attachment|
      emit.call('attachment', attachment.attributes.merge('blob' => blob_info(attachment)))
    end
  end

  def blob_info(attachment)
    blob = attachment.file.attached? ? attachment.file.blob : nil
    blob&.slice('key', 'filename', 'content_type', 'byte_size', 'service_name')
  end

  # ---- delete -------------------------------------------------------------

  def wipe!(contact_ids)
    deleted = Hash.new(0)
    messages.in_batches(of: BATCH) { |batch| delete_messages(batch.pluck(:id), deleted) }
    conversations.in_batches(of: BATCH) { |batch| delete_conversations(batch.pluck(:id), deleted) }
    deleted[:contact_inboxes] += contact_inboxes.delete_all
    contact_ids.each_slice(BATCH) { |ids| delete_contacts(ids, deleted) }
    deleted
  end

  def delete_messages(ids, deleted)
    deleted[:attachments] += Attachment.where(message_id: ids).delete_all
    deleted[:notifications] += delete_rows('notifications', primary_actor_type: 'Message', primary_actor_id: ids)
    deleted[:csat_survey_responses] += delete_rows('csat_survey_responses', message_id: ids)
    deleted[:messages] += Message.where(id: ids).delete_all
  end

  def delete_conversations(ids, deleted)
    leftover = Message.where(conversation_id: ids).pluck(:id)
    delete_messages(leftover, deleted) if leftover.any?
    CONVERSATION_TABLES.each { |table| deleted[table.to_sym] += delete_rows(table, conversation_id: ids) }
    deleted[:notifications] += delete_rows('notifications', primary_actor_type: 'Conversation', primary_actor_id: ids)
    deleted[:taggings] += delete_rows('taggings', taggable_type: 'Conversation', taggable_id: ids)
    deleted[:conversations] += Conversation.where(id: ids).delete_all
  end

  def delete_contacts(ids, deleted)
    # Re-check at delete time: only contacts with no contact_inboxes anywhere.
    still_linked = ContactInbox.where(contact_id: ids).select(:contact_id)
    ids = Contact.where(id: ids, account_id: @inbox.account_id).where.not(id: still_linked).pluck(:id)
    deleted[:notes] += delete_rows('notes', contact_id: ids)
    deleted[:taggings] += delete_rows('taggings', taggable_type: 'Contact', taggable_id: ids)
    deleted[:contacts] += Contact.where(id: ids).delete_all
  end

  # Plain DELETE for tables that may not have a model in this edition (enterprise/captain); skips missing tables.
  def delete_rows(table, conditions)
    conn = ActiveRecord::Base.connection
    return 0 unless conn.data_source_exists?(table)
    return 0 if conditions.values.any? { |value| value.is_a?(Array) && value.empty? }

    clauses = conditions.map do |column, value|
      values = Array(value).map { |item| conn.quote(item) }.join(', ')
      "#{conn.quote_column_name(column)} IN (#{values})"
    end
    conn.exec_delete("DELETE FROM #{conn.quote_table_name(table)} WHERE #{clauses.join(' AND ')}", 'Coro::InboxWiper')
  end
end
