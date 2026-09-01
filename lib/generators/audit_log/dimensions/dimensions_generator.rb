# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"

module AuditLog
  module Generators
    # `rails generate audit_log:dimensions`
    #
    # THE RETROFIT PATH, and only that. A new application already has the
    # `dimensions` column and its facet index -- `audit_tables.sql` creates both
    # with the tables, against nothing, and they cost an application that never
    # declares a facet nothing at all. This generator exists for an established
    # deployment whose audit tables were installed before DESIGN §23 and which has
    # years of rows in place.
    #
    # It is NOT under the `views:` namespace, because it writes no presentational
    # code into the host: it emits a schema migration, which is what
    # `audit_log:trigger` does and what `audit_log:install` does. The `views:`
    # rule is about generated code the host then owns and maintains.
    #
    # The migration it writes does the per-partition CONCURRENTLY dance and
    # asserts the catalog's own completeness flag; see AuditLog::DimensionIndex
    # for why both halves are necessary.
    class DimensionsGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Retrofit the dimensions column and facet index onto an existing audit log."

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_dimensions_migration
        migration_template "dimensions_migration.rb.tt", "db/migrate/add_audit_log_dimensions.rb"
      end

      # DESIGN §21.1: never report success for work it did not do, and never let
      # a step whose failure is invisible pass without saying what it needs.
      def explain
        say ""
        say "  The migration adds `dimensions jsonb` to both audit tables and builds", :yellow
        say "  the facet index ONE PARTITION AT A TIME with CONCURRENTLY, so it never", :yellow
        say "  takes a lock that blocks the audit write path. On a long retention", :yellow
        say "  horizon that is 84 GIN builds and it is not quick -- it prints each", :yellow
        say "  partition as it finishes.", :yellow
        say ""
        say "  It is SAFE TO RE-RUN. CONCURRENTLY cannot run inside a transaction, so"
        say "  the migration disables the DDL transaction and an interruption leaves"
        say "  partial state by construction. Re-running skips what is already"
        say "  attached and drops the INVALID index a failed build leaves behind."
        say ""
        say "  Adding the COLUMN takes a brief ACCESS EXCLUSIVE on each table -- a"
        say "  catalog-only ADD COLUMN, since it is nullable with no default -- so run"
        say "  this in the same window as the rest of your audit maintenance."
        say ""
        say "  Nothing is recorded until a table or an action declares a facet:"
        say "    attach_audit_trigger :invoices, model: \"Invoice\", dimensions: %i[department_id]"
        say "    AuditLog::Registry.register \"invoice.approved\", dimensions: %i[region], ..."
        say "  and it is NOT retroactive -- a facet declared today says nothing about"
        say "  yesterday. See README.md, \"Dimensions\"."
        say ""
      end

      private

      def migration_version
        "[#{::ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
