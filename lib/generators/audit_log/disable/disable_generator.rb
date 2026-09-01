# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"

module AuditLog
  module Generators
    # `rails generate audit_log:disable --reason="..."`
    #
    # Writes a REVERSIBLE migration that detaches every audit trigger in the
    # current schema and, in its `down`, re-attaches exactly what it found. See
    # AuditLog::Capture for why detaching rather than a flag, and DESIGN §25.
    #
    # IT IS A MIGRATION AND NOT A RAKE TASK, which is the decision worth
    # defending. A rake task that drops triggers on production leaves capture off
    # and `db/structure.sql` still claiming it is on -- the schema dump becomes a
    # lie, and the one artifact that would have disclosed the change is the one
    # that does not. A migration gets three things for free instead: the six
    # deleted `CREATE TRIGGER` lines are a reviewable diff, the marker comment
    # appears beside them in the same diff, and `schema_migrations` answers "when
    # did capture stop".
    #
    # It also puts the snapshot where it can be read before it is run. `down`
    # carries literal `attach_audit_trigger` arguments, not a lookup, so what
    # comes back is reviewable rather than trusted.
    #
    # NOT under the `views:` namespace: it writes a schema migration, exactly as
    # `audit_log:trigger` and `audit_log:dimensions` do. `views:` is for
    # presentational code the host then owns (DESIGN §21.3).
    class DisableGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Detach every audit trigger, keeping the audit tables, partitions and rows."

      class_option :reason, type: :string, required: true,
        desc: "Why capture is being disabled. Stored on the audit_events row and in the marker."

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      # Read the catalog BEFORE writing anything, and refuse on an empty result.
      # A migration generated against no triggers detaches nothing, restores
      # nothing, and looks exactly like one that worked. DESIGN §21.1.
      def read_the_catalog
        if AuditLog::Capture.disabled?
          marker = AuditLog::Capture.status
          raise Rails::Generators::Error, <<~MESSAGE
            Capture is already marked disabled (since #{marker["disabled_at"]}, reason:
            #{marker["reason"].inspect}). Generating a second disable migration would
            stamp a new marker over that one and lose the original reason and date.

            To resume, run the `down` of the migration that disabled it, or
            `rails generate audit_log:enable` if that migration is gone.
          MESSAGE
        end

        if triggers.empty?
          raise Rails::Generators::Error, <<~MESSAGE
            No audit triggers are attached in schema #{current_schema.inspect}, so there
            is nothing to disable and nothing this migration could restore.

            If you expected some, check you are pointed at the right database and the
            right schema -- everything in this library operates on current_schema()
            rather than on `public` (DESIGN §14).
          MESSAGE
        end
      end

      def create_disable_migration
        migration_template "disable_migration.rb.tt", "db/migrate/disable_audit_capture.rb"
      end

      def explain
        say ""
        say "  Snapshotted #{triggers.size} trigger#{"s" unless triggers.one?}: " \
            "#{triggers.map { |t| t[:table] }.join(", ")}", :green
        say ""
        say "  This migration keeps EVERYTHING except capture: audit_changes and", :yellow
        say "  audit_events, every partition, every row, and the auditor UI, which", :yellow
        say "  goes on reading the history you already have.", :yellow
        say ""
        say "  What it does not stop is LAYER 2. AuditLog.notify and AuditLog.audited"
        say "  go on writing audit_events rows, so the timeline keeps its narrative and"
        say "  loses the field-level diffs under it. That is what makes the gap legible."
        say ""
        say "  `rake audit_log:coverage` and the shared example WILL FAIL while capture"
        say "  is off, reporting that it is disabled and since when. That is the point"
        say "  of detaching rather than setting a flag -- do not skip the spec to make"
        say "  the build green; resume capture, or accept a red forcing function for as"
        say "  long as the pause lasts."
        say ""
        say "  ONE GENUINELY LOSSY CASE, worth knowing before you accept the gap: a"
        say "  record created AND deleted inside the window leaves no trace that it ever"
        say "  existed. Everything else is a hole you can see the edges of."
        say ""
        say "  Resume with `rails db:migrate:down VERSION=...` on this migration, or"
        say "  `rails generate audit_log:enable` if it is no longer in the repository."
        say ""
      end

      private

      def triggers
        @triggers ||= AuditLog::Capture.attached
      end

      def current_schema
        ActiveRecord::Base.connection.current_schema
      end

      def reason
        options[:reason]
      end

      # The exclusion list nearly every table shares, named once so the restore
      # block reads as a list of tables rather than a wall of column names. Only
      # the tables whose list is not this list plus a suffix spell theirs in full.
      def common_excluded
        @common_excluded ||= triggers.map { |t| t[:excluded] }.tally.max_by { |_, n| n }&.first || []
      end

      def excluded_expression(list)
        return "COMMON_EXCLUDED" if list == common_excluded

        if common_excluded.any? && list.first(common_excluded.size) == common_excluded
          extra = list.drop(common_excluded.size)
          return "COMMON_EXCLUDED + #{words(extra)}"
        end

        words(list)
      end

      def trigger_literal(trigger)
        parts = [
          "table: #{trigger[:table].inspect}",
          "model: #{trigger[:model].inspect}",
          "exclude: #{excluded_expression(trigger[:excluded])}"
        ]
        # OMITTED when the table declared no facet, never `dimensions: []`. The
        # trigger function guards its extraction on `TG_ARGV[2] IS NOT NULL`, so
        # passing an empty list would attach a trigger with an argument the
        # original did not have.
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
