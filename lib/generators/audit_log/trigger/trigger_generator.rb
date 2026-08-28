# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"

module AuditLog
  module Generators
    # `rails generate audit_log:trigger orders --model=Order`
    #
    # A migration attaching the audit trigger to a table that already exists.
    # Attaching beside `create_table` in the migration that creates the table is a
    # review convention, not a requirement -- the helper is a bare CREATE TRIGGER
    # that reads nothing from the create_table beside it.
    class TriggerGenerator < Rails::Generators::NamedBase
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Generate a migration attaching (or re-attaching) the audit trigger to a table."

      argument :name, type: :string, banner: "table"

      class_option :model, type: :string,
        desc: "Model name recorded on every row. Defaults to the table name classified."
      class_option :exclude, type: :array, default: [],
        desc: "Extra columns to keep out of the diff, on top of config.default_excluded_columns"
      class_option :replace, type: :boolean, default: false,
        desc: "Detach first. Required when CHANGING an existing trigger's model or exclusions."

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_trigger_migration
        migration_template "trigger_migration.rb", "db/migrate/#{migration_basename}.rb"
      end

      def warn_about_table_shape
        say ""
        say "  The trigger function assigns `rec_id bigint := NEW.id`, and", :yellow
        say "  audit_changes.record_id is `bigint NOT NULL`. So a table with", :yellow
        say "  an `id: false` shape, a uuid primary key, or a primary key not", :yellow
        say "  named `id` FAILS ON ITS FIRST WRITE after attaching -- not at", :yellow
        say "  migration time. Check the #{table_name} table's primary key first.", :yellow
        say ""

        if options[:replace]
          say "  --replace generates detach-then-attach, which is the supported way to"
          say "  change a table's model or exclusion list. It is NOT retroactive: rows"
          say "  already in audit_changes keep the diffs they were written with."
        else
          say "  If #{table_name} already has a trigger this migration will FAIL with"
          say "  42710 (\"trigger already exists\"). That is deliberate -- the collision"
          say "  is what stops two triggers coexisting on one table and writing two"
          say "  rows per change under different exclusion sets. Use --replace to change"
          say "  an existing one."
        end
        say ""
      end

      private

      def table_name  = name.underscore
      def model_name  = options[:model].presence || table_name.classify
      def excluded    = options[:exclude].map(&:to_s)

      def migration_basename
        options[:replace] ? "reattach_audit_trigger_to_#{table_name}" : "audit_#{table_name}"
      end

      def migration_class_name
        migration_basename.camelize
      end

      def attach_arguments
        args = [":#{table_name}", %(model: "#{model_name}")]
        args << "exclude: %w[#{excluded.join(" ")}]" if excluded.any?
        args.join(", ")
      end

      def migration_version
        "[#{::ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
