# Find-or-create a brand's Coro account by exact name and copy the team from a source account.
# Desk defaults: "show all / hide Mine" is a global dashboard default in this fork
# (ChatList defaults to All, Mine tab hidden), so the only per-account default is
# auto-assignment, which is an inbox-level flag.
class Coro::AccountProvisioner
  def initialize(name:, source_account_id:, dry_run:)
    @name = name.to_s.strip
    @source = Account.find(source_account_id)
    @dry_run = dry_run
  end

  def perform
    raise Coro::Provisioning::Error, 'name is required' if @name.blank?

    account = find_account
    created = account.nil?
    account = Account.create!(name: @name, locale: @source.locale) if created && !@dry_run

    {
      dry_run: @dry_run, account_id: account&.id, account_name: @name, created: created, source_account_id: @source.id,
      account_users: copy_account_users(account),
      desk_defaults: {
        show_all_hide_mine: 'global dashboard default (ChatList defaults to All, Mine tab hidden); nothing per account',
        auto_assignment_disabled_on_inbox_ids: account ? Coro::Provisioning.disable_auto_assignment(account.inboxes, @dry_run) : []
      }
    }
  end

  private

  def find_account
    matches = Account.where(name: @name).to_a
    raise Coro::Provisioning::Error, "#{matches.size} accounts are named #{@name.inspect}; refusing to guess" if matches.size > 1

    matches.first
  end

  # Copies missing users with the source role; never changes an existing member's role (reported instead).
  def copy_account_users(account)
    result = { copied: [], already_present: [], role_mismatch: [] }
    current = account ? account.account_users.to_h { |au| [au.user_id, au.role] } : {}
    @source.account_users.includes(:user).order(:id).each do |source_au|
      entry = { user_id: source_au.user_id, email: source_au.user&.email, role: source_au.role }
      role = current[source_au.user_id]
      next copy_user(account, source_au, result, entry) if role.nil?

      result[:already_present] << entry
      result[:role_mismatch] << entry.merge(current_role: role) if role != source_au.role
    end
    result
  end

  def copy_user(account, source_au, result, entry)
    account.account_users.create!(user_id: source_au.user_id, role: source_au.role) unless @dry_run
    result[:copied] << entry
  end
end
