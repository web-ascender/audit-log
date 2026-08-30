# frozen_string_literal: true

module AuditLog
  # DDL for the audit log itself, so a host application's migration is three
  # lines and the SQL stays versioned inside the library.
  #
  #   class InstallAuditLog < ActiveRecord::Migration[8.1]
  #     def up   = AuditLog::Schema.install!
  #     def down = AuditLog::Schema.uninstall!
  #   end
  #
  # EVERYTHING HERE IS INSTALLED INTO THE CURRENT SCHEMA, not into `public`.
  # For almost every application those are the same thing and this paragraph is
  # noise. It is written down because the alternative is not: `audit_tables.sql`
  # creates its tables unqualified, so they follow `search_path` -- while the
  # trigger function used to be pinned to `public`, which meant that in an
  # application whose search_path was anything else, the tables landed in one
  # schema and every row the triggers wrote landed in another. Nothing reported
  # it: the writes succeeded, against the wrong table.
  #
  # So the function is installed beside the tables it writes to, and names them
  # in full. `install_function!` run under a different search_path installs a
  # second, independent copy -- which is the whole mechanism by which an
  # application that puts each tenant in its own schema gets a working audit log
  # per schema without this library knowing that it does.
  module Schema
    # AuditLog::GEM_ROOT rather than Engine.root: this DDL is called from a
    # migration, and a migration must not depend on the engine being booted.
    SQL_DIR = File.expand_path("db/sql", AuditLog::GEM_ROOT)

    # A schema name needing no quoting, which is every schema name Rails or a
    # tenancy library will produce.
    BARE_IDENTIFIER = /\A[a-z_][a-z0-9_]*\z/

    class << self
      def install!(connection = ActiveRecord::Base.connection)
        connection.execute(read("audit_tables"))
        install_function!(connection)
        AuditLog::Partitions.ensure!(connection: connection)
      end

      # Idempotent, and separated so a later change to the function body can be
      # deployed by a migration that only calls this.
      def install_function!(connection = ActiveRecord::Base.connection)
        connection.execute(function_sql(connection))
      end

      def uninstall!(connection = ActiveRecord::Base.connection)
        connection.execute("DROP TABLE IF EXISTS audit_changes CASCADE")
        connection.execute("DROP TABLE IF EXISTS audit_events  CASCADE")
        connection.execute("DROP FUNCTION IF EXISTS #{qualified_function_name(connection)} CASCADE")
      end

      # The function's DDL with {{schema}} resolved. Public so a host app can read
      # what it is about to install, and so a spec can assert against it.
      def function_sql(connection = ActiveRecord::Base.connection)
        read("audit_row_change").gsub("{{schema}}", quoted_current_schema(connection))
      end

      def qualified_function_name(connection = ActiveRecord::Base.connection)
        "#{quoted_current_schema(connection)}.audit_row_change()"
      end

      def read(name)
        File.read(File.join(SQL_DIR, "#{name}.sql"))
      end

      private

      # Rendered the way pg_dump renders it -- bare when the identifier needs no
      # quoting -- so the stored function body reads as an ordinary
      # `schema.table` reference rather than as generated SQL. Anything else is
      # quoted, because a schema name is not this library's to assume about.
      def quoted_current_schema(connection)
        schema = connection.current_schema
        schema.match?(BARE_IDENTIFIER) ? schema : connection.quote_table_name(schema)
      end
    end
  end
end
