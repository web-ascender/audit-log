# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"

module AuditLog
  module Generators
    # `rails generate audit_log:enable`
    #
    # THE RECOVERY PATH, and only that. DESIGN §25.
    #
    # The ordinary way to resume capture is the `down` of the migration
    # `audit_log:disable` wrote -- `rails db:migrate:down VERSION=...` -- and that
    # is also the whole ping-pong cycle, because `db:migrate:up` on the same
    # migration disables it again. One migration, reversible, as many times as you
    # like.
    #
    # This generator exists for the case where that migration is gone: squashed,
    # deleted, or simply not in the checkout somebody is holding while capture is
    # off in the database in front of them. At that moment the triggers no longer
    # exist, so the catalog cannot say what they were -- and the marker
    # AuditLog::Capture stamped is the only remaining record. It reads that, and
    # refuses if it is not there rather than reconstructing model names from table
    # names, which would silently mislabel `record_type` on every row written
    # afterwards (`orders.created_by_id` points at `User`; the same class of
    # guess `RecordLabel` refuses to make).
    class EnableGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Re-attach the audit triggers recorded by audit_log:disable (recovery path)."

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def read_the_marker
        unless AuditLog::Capture.disabled?
          raise Rails::Generators::Error, <<~MESSAGE
            Capture is not marked disabled in schema #{current_schema.inspect}, so there
            is nothing here to resume.

            If triggers are genuinely missing but no marker is present, they were not
            detached by this library and it has no record of what they were. Use
            `rails generate audit_log:trigger <table> --model=<Model>` per table, and
            check `rake audit_log:coverage` for the full list of what is untracked.
          MESSAGE
        end

        if triggers.empty?
          raise Rails::Generators::Error, <<~MESSAGE
            Capture is marked disabled (since #{marker["disabled_at"]}, reason:
            #{marker["reason"].inspect}) but the marker carries no trigger snapshot, so
            this generator cannot say what to re-attach and will not guess.

            Recover the `audit_log:disable` migration from version control -- its
            `down` holds the same list -- or write the `attach_audit_trigger` lines by
            hand. `rake audit_log:coverage` names every table now untracked.
          MESSAGE
        end
      end

      def create_enable_migration
        migration_template "enable_migration.rb.tt", "db/migrate/enable_audit_capture.rb"
      end

      def explain
        say ""
        say "  Recovered #{triggers.size} trigger#{"s" unless triggers.one?} from the marker " \
            "stamped #{marker["disabled_at"]}.", :green
        say "  Reason recorded at the time: #{marker["reason"].inspect}"
        say ""
        say "  CHECK THE MODEL NAMES BEFORE RUNNING IT. They are what the triggers", :yellow
        say "  carried when capture was disabled; if a model has been renamed since,", :yellow
        say "  `record_type` will disagree with your codebase and the auditor UI will", :yellow
        say "  resolve labels for a class that no longer exists.", :yellow
        say ""
        say "  Capture resumes for writes AFTER this migration runs. The window stays"
        say "  a gap -- there is no backfill, and there could not be one: the rows that"
        say "  would describe it were never written."
        say ""
        say "  Prefer `rails db:migrate:down VERSION=...` on the original disable"
        say "  migration if you still have it. That is the supported cycle, and it"
        say "  leaves one migration in the repository instead of two."
        say ""
      end

      private

      def marker
        @marker ||= AuditLog::Capture.status || {}
      end

      def triggers
        @triggers ||= AuditLog::Capture.snapshot
      end

      def current_schema
        ActiveRecord::Base.connection.current_schema
      end

      def common_excluded
        @common_excluded ||= triggers.map { |t| t[:excluded] }.tally.max_by { |_, n| n }&.first || []
      end

      def excluded_expression(list)
        return "COMMON_EXCLUDED" if list == common_excluded

        if common_excluded.any? && list.first(common_excluded.size) == common_excluded
          return "COMMON_EXCLUDED + #{words(list.drop(common_excluded.size))}"
        end

        words(list)
      end

      def trigger_literal(trigger)
        parts = [
          "table: #{trigger[:table].inspect}",
          "model: #{trigger[:model].inspect}",
          "exclude: #{excluded_expression(trigger[:excluded])}"
        ]
        parts << "dimensions: #{words(trigger[:dimensions])}" if trigger[:dimensions].any?
        "{ #{parts.join(", ")} }"
      end

      def words(list)
        list.empty? ? "%w[]" : "%w[#{list.join(" ")}]"
      end

      def migration_version
        "[#{::ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
