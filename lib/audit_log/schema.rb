# frozen_string_literal: true

module AuditLog
  # DDL for the audit log itself, so a host application's migration is three
  # lines and the SQL stays versioned inside the library.
  #
  #   class InstallAuditLog < ActiveRecord::Migration[8.1]
  #     def up   = AuditLog::Schema.install!
  #     def down = AuditLog::Schema.uninstall!
  #   end
  module Schema
    # AuditLog::GEM_ROOT rather than Engine.root: this DDL is called from a
    # migration, and a migration must not depend on the engine being booted.
    SQL_DIR = File.expand_path("db/sql", AuditLog::GEM_ROOT)

    class << self
      def install!(connection = ActiveRecord::Base.connection)
        connection.execute(read("audit_tables"))
        install_function!(connection)
        AuditLog::Partitions.ensure!(connection: connection)
      end

      # Idempotent, and separated so a later change to the function body can be
      # deployed by a migration that only calls this.
      def install_function!(connection = ActiveRecord::Base.connection)
        connection.execute(read("audit_row_change"))
      end

      def uninstall!(connection = ActiveRecord::Base.connection)
        connection.execute("DROP TABLE IF EXISTS audit_changes CASCADE")
        connection.execute("DROP TABLE IF EXISTS audit_events  CASCADE")
        connection.execute("DROP FUNCTION IF EXISTS public.audit_row_change() CASCADE")
      end

      def read(name)
        File.read(File.join(SQL_DIR, "#{name}.sql"))
      end
    end
  end
end
