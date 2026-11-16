# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Coro::Provisioning do
  let(:graph) { %r{\Ahttps://graph\.facebook\.com/} }
  let(:source) { create(:account) }
  let(:admin) { create(:user) }
  let(:agent) { create(:user) }
  let(:api_key) { 'dh_live_secret_line_key' }
  let(:line) { { inbox_name: 'Acme Desk', phone_e164: '+971543283757', phone_number_id: '531873576683853', waba_id: '557383667453816' } }

  before do
    create(:account_user, account: source, user: admin, role: :administrator)
    create(:account_user, account: source, user: agent, role: :agent)
    stub_request(:any, graph).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, %r{\Ahttps://api\.dualhook\.com/v25\.0/\d+/message_templates})
      .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe Coro::AccountProvisioner do
    it 'creates the account and copies account users with the same roles, idempotently' do
      result = described_class.new(name: 'Acme Pets', source_account_id: source.id, dry_run: false).perform
      account = Account.find(result[:account_id])

      expect(result[:created]).to be true
      expect(account.account_users.to_h { |au| [au.user_id, au.role] }).to eq(admin.id => 'administrator', agent.id => 'agent')

      again = described_class.new(name: 'Acme Pets', source_account_id: source.id, dry_run: false).perform
      expect(again[:created]).to be false
      expect(again[:account_id]).to eq(account.id)
      expect(again[:account_users][:copied]).to be_empty
    end

    it 'writes nothing in dry run' do
      expect do
        described_class.new(name: 'Dry Pets', source_account_id: source.id, dry_run: true).perform
      end.not_to change(Account, :count)
    end
  end

  describe Coro::InboxProvisioner do
    let(:account) { Account.find(Coro::AccountProvisioner.new(name: 'Acme Pets', source_account_id: source.id, dry_run: false).perform[:account_id]) }

    def provision(dry_run: false, key: api_key, target: account)
      described_class.new(account_id: target.id, line: line, api_key: key, dry_run: dry_run).perform
    end

    it 'creates an externally managed inbox with all account users as members and no Graph calls' do
      result = provision
      inbox = Inbox.find(result[:inbox_id])

      expect(inbox.channel).to be_externally_managed
      expect(inbox.channel.provider_config.slice('api_key', 'phone_number_id', 'business_account_id'))
        .to eq('api_key' => api_key, 'phone_number_id' => line[:phone_number_id], 'business_account_id' => line[:waba_id])
      expect(inbox.enable_auto_assignment).to be false
      expect(inbox.inbox_members.pluck(:user_id)).to contain_exactly(admin.id, agent.id)
      expect(result.to_json).not_to include(api_key)
      expect(a_request(:any, graph)).not_to have_been_made
    end

    it 'updates in place on rerun instead of recreating' do
      first = provision
      second = provision(key: 'dh_live_rotated')

      expect(second[:action]).to eq('updated')
      expect(second[:inbox_id]).to eq(first[:inbox_id])
      expect(Channel::Whatsapp.find(first[:channel_id]).provider_config['api_key']).to eq('dh_live_rotated')
    end

    it 'refuses a phone number that belongs to another account' do
      provision
      other = create(:account)

      expect { provision(target: other) }.to raise_error(Coro::Provisioning::Error, /already belongs to account/)
    end

    it 'refuses non-Dualhook keys' do
      expect { provision(key: 'EAAG_meta_token') }.to raise_error(Coro::Provisioning::Error, /not a Dualhook key/)
    end

    it 'writes nothing in dry run' do
      account
      expect { provision(dry_run: true) }.not_to change(Channel::Whatsapp, :count)
    end
  end

  describe Coro::InboxRekeyer do
    it 'swaps the key in place, marks it externally managed and clears reauthorization' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      channel.prompt_reauthorization!

      result = described_class.new(inbox_id: channel.inbox.id, api_key: 'dh_live_new', phone_number_id: '111', waba_id: '222',
                                   dry_run: false).perform
      channel.reload

      expect(channel.provider_config).to include('api_key' => 'dh_live_new', 'phone_number_id' => '111',
                                                 'business_account_id' => '222', 'externally_managed' => true)
      expect(result[:reauthorization_required_after]).to be false
      expect(Inbox.exists?(result[:inbox_id])).to be true
      expect(a_request(:any, graph)).not_to have_been_made
    end
  end

  describe Coro::ExternallyManagedMarker do
    it 'flags inboxes without touching keys, and does nothing in dry run' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)

      described_class.new(inbox_ids: [channel.inbox.id], dry_run: true).perform
      expect(channel.reload).not_to be_externally_managed

      described_class.new(inbox_ids: [channel.inbox.id], dry_run: false).perform
      expect(channel.reload).to be_externally_managed
      expect(channel.provider_config['api_key']).to eq('test_key')
    end
  end

  describe Coro::DeskReport do
    it 'reports provider_config keys but never key values' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)

      report = described_class.new(account_id: channel.account_id, inbox_id: channel.inbox.id).perform

      expect(report[:provider_config_keys]).to include('api_key', 'phone_number_id')
      expect(report.to_json).not_to include('test_key')
    end
  end
end
