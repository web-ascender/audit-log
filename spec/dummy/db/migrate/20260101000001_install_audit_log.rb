# frozen_string_literal: true

# The whole of the audit schema: two partitioned tables, their indexes, and the
# trigger function. Exactly what `rails generate audit_log:install` writes into a
# host app.
class InstallAuditLog < ActiveRecord::Migration[8.1]
  def up   = AuditLog::Schema.install!(connection)
  def down = AuditLog::Schema.uninstall!(connection)
end
