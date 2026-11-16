# Coro Inbox desk provisioning for externally managed (Dualhook) WhatsApp lines.
#
# All tasks print JSON, are idempotent, and honour DRY_RUN=1 (report only, no writes).
# The line key is read from ENV CORO_LINE_API_KEY only (never an argument) and is
# never printed: output carries a fingerprint (prefix, length, short sha256).
#
# zsh: quote the task name, e.g.
#   DRY_RUN=1 bundle exec rake 'coro:provision_account[Acme Pets,4]'
#   CORO_LINE_API_KEY=dh_live_... bundle exec rake 'coro:provision_inbox[9,Acme Desk,+971500000000,1234,5678]'
#   CORO_LINE_API_KEY=dh_live_... bundle exec rake 'coro:rekey_inbox[5]'            # keep ids
#   CORO_LINE_API_KEY=dh_live_... bundle exec rake 'coro:rekey_inbox[5,1234,5678]'  # new ids
#   bundle exec rake 'coro:verify_desk[7,5]'
#   DRY_RUN=1 bundle exec rake 'coro:mark_externally_managed[1,3,4,5,6]'
#   bundle exec rake 'coro:wipe_inbox[5]'                                   # counts only
#   CONFIRM=5 BACKUP_DIR=/data/backups bundle exec rake 'coro:wipe_inbox[5]' # backup + wipe
module CoroProvisioningRake
  module_function

  def dry_run?
    ENV.fetch('DRY_RUN', nil) == '1'
  end

  def run
    puts JSON.pretty_generate(yield)
  rescue Coro::Provisioning::Error, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid => e
    puts JSON.pretty_generate({ error: e.message, error_class: e.class.name })
    exit 1
  end

  def require_args!(args, *names)
    missing = names.select { |name| args[name].blank? }
    raise Coro::Provisioning::Error, "missing task args: #{missing.join(', ')}" if missing.any?
  end
end

namespace :coro do # rubocop:disable Metrics/BlockLength
  desc 'Find-or-create a brand account by exact name and copy account users from a source account. DRY_RUN=1 supported.'
  task :provision_account, [:name, :source_account_id] => :environment do |_task, args|
    CoroProvisioningRake.run do
      CoroProvisioningRake.require_args!(args, :name, :source_account_id)
      Coro::AccountProvisioner.new(name: args[:name], source_account_id: args[:source_account_id],
                                   dry_run: CoroProvisioningRake.dry_run?).perform
    end
  end

  desc 'Create/update an externally managed WhatsApp Cloud inbox (key from ENV CORO_LINE_API_KEY). DRY_RUN=1 supported.'
  task :provision_inbox, [:account_id, :inbox_name, :phone_e164, :phone_number_id, :waba_id] => :environment do |_task, args|
    CoroProvisioningRake.run do
      CoroProvisioningRake.require_args!(args, :account_id, :inbox_name, :phone_e164, :phone_number_id, :waba_id)
      Coro::InboxProvisioner.new(
        account_id: args[:account_id],
        line: { inbox_name: args[:inbox_name], phone_e164: args[:phone_e164], phone_number_id: args[:phone_number_id], waba_id: args[:waba_id] },
        api_key: ENV.fetch('CORO_LINE_API_KEY', nil),
        dry_run: CoroProvisioningRake.dry_run?
      ).perform
    end
  end

  desc 'Swap an existing WhatsApp inbox to a new key (ENV CORO_LINE_API_KEY) in place, mark externally managed. DRY_RUN=1 supported.'
  task :rekey_inbox, [:inbox_id, :phone_number_id, :waba_id] => :environment do |_task, args|
    CoroProvisioningRake.run do
      CoroProvisioningRake.require_args!(args, :inbox_id)
      Coro::InboxRekeyer.new(inbox_id: args[:inbox_id], api_key: ENV.fetch('CORO_LINE_API_KEY', nil),
                             phone_number_id: args[:phone_number_id], waba_id: args[:waba_id],
                             dry_run: CoroProvisioningRake.dry_run?).perform
    end
  end

  desc 'Read-only report of a desk: members, account users, externally_managed, phone, provider_config keys, reauth state.'
  task :verify_desk, [:account_id, :inbox_id] => :environment do |_task, args|
    CoroProvisioningRake.run do
      CoroProvisioningRake.require_args!(args, :account_id, :inbox_id)
      Coro::DeskReport.new(account_id: args[:account_id], inbox_id: args[:inbox_id]).perform
    end
  end

  desc 'One-off: flag existing WhatsApp inboxes as externally managed (ids comma-separated). DRY_RUN=1 supported.'
  task :mark_externally_managed, [:inbox_ids] => :environment do |_task, args|
    CoroProvisioningRake.run do
      ids = [args[:inbox_ids], *args.extras].flat_map { |value| value.to_s.split(/[\s|]+/) }.compact_blank.map(&:to_i)
      raise Coro::Provisioning::Error, 'pass inbox ids, e.g. coro:mark_externally_managed[1,3,4]' if ids.empty?

      { dry_run: CoroProvisioningRake.dry_run?,
        inboxes: Coro::ExternallyManagedMarker.new(inbox_ids: ids, dry_run: CoroProvisioningRake.dry_run?).perform }
    end
  end

  desc 'Wipe an inbox history (backup first; keeps Inbox + Channel). Deletes only with CONFIRM=<inbox_id> and no DRY_RUN=1.'
  task :wipe_inbox, [:inbox_id] => :environment do |_task, args|
    CoroProvisioningRake.run do
      CoroProvisioningRake.require_args!(args, :inbox_id)
      confirmed = ENV.fetch('CONFIRM', nil).to_s == args[:inbox_id].to_s
      Coro::InboxWiper.new(inbox_id: args[:inbox_id], execute: confirmed && !CoroProvisioningRake.dry_run?,
                           backup_dir: ENV.fetch('BACKUP_DIR', nil)).perform
    end
  end
end
