# frozen_string_literal: true

require 'rails_helper'

# Coro: inboxes whose Meta webhook is owned by company-chat (Dualhook WABA-level
# override). Creating or destroying them must never talk to graph.facebook.com —
# a phone-level override_callback_uri would hijack the line from Dualhook.
RSpec.describe Channel::Whatsapp, 'externally managed' do
  let(:account) { create(:account) }
  let(:graph) { %r{\Ahttps://graph\.facebook\.com/} }
  let(:dualhook_templates_url) { 'https://api.dualhook.com/v25.0/557383667453816/message_templates' }
  let(:provider_config) do
    {
      'api_key' => 'dh_live_test_key',
      'phone_number_id' => '531873576683853',
      'business_account_id' => '557383667453816',
      'externally_managed' => true
    }
  end

  before do
    stub_request(:any, graph).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, dualhook_templates_url)
      .with(headers: { 'Authorization' => 'Bearer dh_live_test_key' })
      .to_return(status: 200, body: { data: [{ name: 'hello' }] }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def create_channel(config = provider_config)
    channel = Channel::Whatsapp.create!(account: account, phone_number: '+971543283757', provider: 'whatsapp_cloud', provider_config: config)
    Inbox.create!(account: account, channel: channel, name: 'Desk', enable_auto_assignment: false)
    channel
  end

  it 'makes zero Graph calls on create and destroy' do
    channel = create_channel

    expect(channel).to be_externally_managed
    expect(channel.reload.provider_config).not_to have_key('verification_pin')

    channel.inbox.destroy!
    channel.reload.destroy! if Channel::Whatsapp.exists?(channel.id)

    expect(a_request(:any, graph)).not_to have_been_made
  end

  it 'syncs templates on create through Dualhook with Bearer auth' do
    channel = create_channel

    expect(a_request(:get, dualhook_templates_url)).to have_been_made.once
    expect(channel.reload.message_templates).to eq([{ 'name' => 'hello' }])
  end

  it 'does not prompt reauthorization on create' do
    channel = create_channel

    expect(channel.reauthorization_required?).to be false
  end

  it 'validates offline and requires the routing keys' do
    channel = Channel::Whatsapp.new(account: account, phone_number: '+971500000001', provider: 'whatsapp_cloud',
                                    provider_config: provider_config.except('phone_number_id'))

    expect(channel).not_to be_valid
    expect(channel.errors[:provider_config].join).to include('phone_number_id')
    expect(a_request(:any, /dualhook|facebook/)).not_to have_been_made
  end

  it 'skips inline template sync for a non-Dualhook key so create stays off Graph' do
    create_channel(provider_config.merge('api_key' => 'EAAG_meta_token'))

    expect(a_request(:any, graph)).not_to have_been_made
  end

  it 'refuses WebhookSetupService registration' do
    channel = create_channel

    expect { Whatsapp::WebhookSetupService.new(channel).register_callback }
      .to raise_error(Whatsapp::WebhookSetupService::ExternallyManagedError)
    expect(a_request(:any, graph)).not_to have_been_made
  end

  it 'keeps the flag when a settings save posts provider_config without it' do
    channel = create_channel

    channel.update!(provider_config: provider_config.except('externally_managed'))

    expect(channel.reload).to be_externally_managed
  end

  it 'still sets a phone-level webhook for ordinary manual inboxes (guard is opt-in)' do
    channel = Channel::Whatsapp.new(account: account, phone_number: '+971500000002', provider: 'whatsapp_cloud',
                                    provider_config: provider_config.except('externally_managed'))

    expect(channel.send(:should_auto_setup_webhooks?)).to be true
  end

  describe Msh::SyncWhatsappTokenJob do
    around do |example|
      original = ENV.fetch('WHATSAPP_DUALHOOK_API_KEY', nil)
      ENV['WHATSAPP_DUALHOOK_API_KEY'] = 'dh_live_rotated_key'
      example.run
    ensure
      ENV['WHATSAPP_DUALHOOK_API_KEY'] = original
    end

    it 'leaves an externally managed MSH inbox key alone' do
      channel = Channel::Whatsapp.create!(account: account, phone_number: Msh::SyncWhatsappTokenJob::MSH_PHONE_NUMBER,
                                          provider: 'whatsapp_cloud', provider_config: provider_config)

      described_class.perform_now

      expect(channel.reload.provider_config['api_key']).to eq('dh_live_test_key')
      expect(a_request(:any, graph)).not_to have_been_made
    end
  end
end
