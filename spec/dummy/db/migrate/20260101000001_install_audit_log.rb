# frozen_string_literal: true

# The whole of the audit schema: two partitioned tables, their indexes, and the
# trigger function. Exactly what `rails generate audit_log:install` writes into a
# host app.
# 8.0, not 8.1, and that is the FLOOR of `rails ~> 8.0` rather than a stale
# number. Rails 8.0 rejects a migration declared at a version it does not know --
# `Unknown migration version "8.1"` -- so a dummy app pinned to 8.1 cannot migrate
# on the floor leg at all. It went unnoticed locally because an already-migrated
# database never loads the file; CI creates a fresh one, which is the difference.
# The install GENERATOR was always right about this: it emits
# `ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]`, so an
# adopter's migration matches their own Rails.
class InstallAuditLog < ActiveRecord::Migration[8.0]
  def up   = AuditLog::Schema.install!(connection)
  def down = AuditLog::Schema.uninstall!(connection)
end
