# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Coro::InboxWiper do
  let(:graph) { %r{\Ahttps://graph\.facebook\.com/} }
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
  end
  let(:inbox) { channel.inbox }
  let(:other_inbox) { create(:inbox, account: account) }
  let(:only_here) { create(:contact, account: account) }
  let(:shared) { create(:contact, account: account) }
  let(:backup_dir) { Dir.mktmpdir }

  before do
    stub_request(:any, graph).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    [only_here, shared].each do |contact|
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: SecureRandom.random_number(10**12).to_s)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, source_id: "wamid.#{SecureRandom.hex(4)}")
    end
    other_ci = create(:contact_inbox, contact: shared, inbox: other_inbox)
    other_conversation = create(:conversation, account: account, inbox: other_inbox, contact: shared, contact_inbox: other_ci)
    create(:message, account: account, inbox: other_inbox, conversation: other_conversation)
  end

  after { FileUtils.remove_entry(backup_dir) }

  it 'only reports counts when not executing' do
    result = nil
    expect { result = described_class.new(inbox_id: inbox.id, execute: false, backup_dir: backup_dir).perform }
      .not_to change(Message, :count)

    expect(result[:counts]).to include(conversations: 2, messages: 2, contact_inboxes: 2, contacts_only_in_this_inbox: 1)
    expect(Dir.children(backup_dir)).to be_empty
  end

  context 'when executing' do
    let(:result) { described_class.new(inbox_id: inbox.id, execute: true, backup_dir: backup_dir).perform }
    let(:backup_lines) { Zlib::GzipReader.open(result[:backup][:path]) { |gz| gz.each_line.map { |line| JSON.parse(line) } } }

    it 'never destroys the inbox or channel, calls Meta, or enqueues jobs' do
      expect(Whatsapp::WebhookTeardownService).not_to receive(:new)

      expect { result }.not_to have_enqueued_job

      expect(Inbox.exists?(inbox.id)).to be true
      expect(Channel::Whatsapp.exists?(channel.id)).to be true
      expect(result).to include(inbox_preserved: true, channel_preserved: true)
      expect(a_request(:any, graph)).not_to have_been_made
    end

    it 'wipes this inbox history and contacts that were only in this inbox' do
      result

      expect([Conversation, Message, ContactInbox].map { |model| model.where(inbox_id: inbox.id).count }).to eq([0, 0, 0])
      expect(Contact.exists?(only_here.id)).to be false
      expect(Contact.exists?(shared.id)).to be true
      expect(Message.where(inbox_id: other_inbox.id).count).to eq(1)
    end

    it 'writes a gzipped JSONL backup first' do
      expect(backup_lines.map { |line| line['type'] }.tally)
        .to include('meta' => 1, 'conversation' => 2, 'message' => 2, 'contact_inbox' => 2, 'contact' => 1)
      expect(backup_lines.select { |line| line['type'] == 'message' }.map { |line| line['data']['source_id'] }).to all(start_with('wamid.'))
    end
  end
end
