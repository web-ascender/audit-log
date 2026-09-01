# frozen_string_literal: true

module AuditLog
  # Turning layer 1 OFF, and turning it back on, without losing a row of what it
  # already recorded. DESIGN §25.
  #
  # Two situations, and only the second is a cycle:
  #
  #   * you are removing the gem, and do not want triggers left behind writing to
  #     tables nothing reads;
  #   * you want to stop capture for a window -- a bulk migration too large for
  #     AuditLog::Bypass, a staging database, a cost decision -- and resume later
  #     with the audit log intact and a gap in it you have accounted for.
  #
  # Both are the same mechanism: DROP the triggers, keep the tables, the
  # partitions, the rows and the auditor UI exactly as they are.
  #
  # ---------------------------------------------------------------------------
  # WHY DETACHING, AND NOT A FLAG THE TRIGGER READS
  #
  # The obvious cheaper design is a fifth early exit in audit_row_change() beside
  # `audit.bypass`, reading a setting made durable with `ALTER DATABASE ... SET`.
  # It needs no locks, keeps every trigger attached, and is a one-line toggle.
  #
  # It is also the one thing this library must not build: it would pass
  # `rake audit_log:coverage` and the shared example while auditing nothing.
  # Every table would still have its trigger, `pg_trigger` would still vouch for
  # it, `db/structure.sql` would be unchanged, and capture would be off --
  # invisible to the forcing function whose entire job is noticing that. Bypass
  # gets away with a GUC because it is scoped to a block and narrates itself;
  # a durable flag is neither.
  #
  # Detaching is the honest disable precisely BECAUSE it is loud. Coverage fails,
  # and `Coverage#report` reads the marker below so it fails saying "capture is
  # disabled" rather than sending somebody to write attach migrations.
  #
  # ---------------------------------------------------------------------------
  # WHERE THE STATE LIVES, AND WHY IN TWO PLACES
  #
  # THE SNAPSHOT IS WRITTEN TWICE, ON PURPOSE, and neither copy is redundant.
  #
  # IN THE MIGRATION, as literal `attach_audit_trigger` arguments. What comes
  # back has to be reviewable in a diff BEFORE it is run -- the same argument
  # `bypass_allowlist` makes for being a config file rather than a runtime grant.
  # This is the copy that resumes capture in the ordinary case, and the only one
  # a reviewer ever reads.
  #
  # IN THE MARKER, which is a table comment on `audit_changes`, in the idiom
  # AuditLog::Partitions already uses three times (RETIRED_MARKER, ROLLUP_MARKER,
  # FROZEN_MARKER). It carries the reason, the timestamp AND the full snapshot,
  # because the migration can be squashed, deleted or simply not present in the
  # checkout somebody is holding -- and at that moment the triggers are gone and
  # the catalog can no longer say what they were. Without this copy the recovery
  # is guessing model names from table names, which is the sniffing
  # `RecordLabel` refuses to do, applied somewhere it would silently mislabel
  # every row written afterwards. `audit_log:enable` reads it.
  #
  # The marker goes on the PARENT, which no partition path ever comments on --
  # `frozen_partitions` joins through pg_inherits, so it cannot see the parent and
  # cannot clear this.
  #
  # Both are then in version control for free, because `schema_format = :sql`
  # means the triggers vanishing and the comment appearing are one reviewable
  # diff in `db/structure.sql`. That disclosure is not something this module
  # arranges; it is a property of the host being on :sql, which this library
  # already requires.
  #
  # ---------------------------------------------------------------------------
  # WHAT THIS DOES NOT STOP: LAYER 2
  #
  # `AuditLog.notify` and `AuditLog.audited` go on working, so a paused
  # application keeps writing audit_events rows and the timeline keeps rendering
  # narrative activities with no field changes under them. That is deliberate and
  # it is not a half-measure -- it is what makes the gap legible rather than
  # blank. There is NO `config.enabled = false`, for the reason
  # `retention_action` is gone: a flag that silently no-ops the audit trail is a
  # flag somebody flips. An application that wants layer 2 off too stops calling
  # it, or clears the registry.
  module Capture
    MARKER = "audit_log:capture-disabled"

    DISABLED_ACTION = "audit.capture_disabled"
    RESUMED_ACTION  = "audit.capture_resumed"

    # The marker goes here, not on audit_events: this is layer 1's destination,
    # and layer 1 is the only thing being disabled.
    MARKED_TABLE = "audit_changes"

    class << self
      # Every audited table in the current schema, with the arguments its trigger
      # actually carries -- read from `tgargs` rather than from the migration
      # history, for the reason Coverage reads pg_trigger: the migrations are what
      # somebody meant, the catalog is what is true.
      #
      # tgargs is a bytea of null-terminated strings. `encode(..., 'escape')` plus
      # a split is robust where parsing `pg_get_triggerdef` is not -- the model
      # name is an arbitrary string this library never validated, so a regex over
      # the rendered DDL has a quoting hole in it that this does not.
      #
      # SCOPED TO current_schema() for the reason everything here is (DESIGN §14):
      # unscoped, one schema's triggers would be snapshotted and another schema's
      # detached.
      def attached(connection: ActiveRecord::Base.connection)
        rows = connection.select_rows(<<~SQL)
          SELECT c.relname,
                 t.tgname,
                 a.args[1],
                 a.args[2],
                 CASE WHEN t.tgnargs >= 3 THEN a.args[3] END
          FROM   pg_trigger t
          JOIN   pg_class c ON c.oid = t.tgrelid
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          CROSS  JOIN LATERAL (
                   SELECT string_to_array(encode(t.tgargs, 'escape'), '\\000') AS args
                 ) a
          WHERE  NOT t.tgisinternal
            AND  t.tgname LIKE '%\\_audit'
            AND  n.nspname = current_schema()
          ORDER  BY c.relname
        SQL

        rows.map do |table, trigger, excluded, model, dimensions|
          {
            table:      table,
            trigger:    trigger,
            # TG_ARGV[0] is the MERGED list -- config.default_excluded_columns plus
            # the migration's `exclude:`. It is handed back whole rather than
            # split, and the generator writes it back whole as `exclude:`, because
            # `attach_audit_trigger` computes `(defaults + exclude).uniq`: passing
            # the merged list reproduces it byte for byte, and still reproduces
            # every exclusion the table had if `default_excluded_columns` has
            # changed in between. Subtracting the current defaults to recover the
            # original `exclude:` reads better and loses an exclusion the day
            # somebody removes a default.
            excluded:   split_list(excluded),
            model:      model,
            # ABSENT, not empty, on a table that declared no facet -- the trigger
            # function's extraction block is guarded on `TG_ARGV[2] IS NOT NULL`,
            # so re-attaching with `dimensions: []` is the same thing and the
            # generator omits the argument entirely. The `tgnargs >= 3` guard is
            # what tells a genuinely absent third argument from the empty string
            # the bytea's null terminator leaves behind when the split runs off
            # the end -- without it every table looks like it declared a facet.
            dimensions: split_list(dimensions)
          }
        end
      end

      # Narrate, then stamp the marker. The DETACH itself is the migration's, via
      # the published `detach_audit_trigger` helper -- this module does not
      # duplicate DDL that already has a home.
      #
      # NARRATED FIRST, and inside the caller's transaction, which is the order
      # AuditLog::Bypass uses and for the same reason: the log can never hold a
      # gap that nothing accounts for. The event is therefore written while
      # capture is still on, so its own request_id still correlates with whatever
      # else that unit of work touched.
      def disable!(reason:, triggers:, connection: ActiveRecord::Base.connection)
        raise ArgumentError, "a reason is required" if reason.blank?
        raise ArgumentError, "no triggers to disable" if Array(triggers).empty?

        require_registered!(DISABLED_ACTION)

        snapshot = Array(triggers).map { |t| normalize(t) }

        AuditLog.notify(DISABLED_ACTION,
                        reason: reason,
                        tables: snapshot.map { |t| t["table"] })
        mark!(reason: reason, snapshot: snapshot, connection: connection)
      end

      # Clear the marker, then narrate. The reverse order of `disable!`, and for
      # the mirror-image reason: the resume event belongs INSIDE the period it
      # resumes, so it is written after the triggers are back and the marker is
      # gone. Whatever it touches is captured again.
      def enable!(reason: nil, tables: [], connection: ActiveRecord::Base.connection)
        require_registered!(RESUMED_ACTION)

        was = status(connection: connection)
        clear_marker!(connection: connection)

        AuditLog.notify(RESUMED_ACTION,
                        reason: reason.presence || was&.dig("reason"),
                        disabled_at: was&.dig("disabled_at"),
                        tables: Array(tables).map(&:to_s))
      end

      # THE NARRATION IS NOT OPTIONAL, so its absence is a raise rather than a
      # silent skip. `EventSubscriber#emit` is `Registry[name] or return`, so an
      # unregistered action writes nothing and reports nothing -- which for a
      # deliberate gap in an audit log is the worst available outcome. DESIGN
      # §21.1: never report success for work it did not do.
      #
      # (The same hole is why `audit.bypass` and `audit.redaction` are now in the
      # install generator's initializer template. Before that they were registered
      # only by spec/dummy, so `Bypass.call`'s "the bypass logs itself" guarantee
      # quietly did not hold in any real adopting application.)
      def require_registered!(action)
        return if AuditLog::Registry[action]

        raise AuditLog::Error, <<~MESSAGE
          #{action} has no registry entry, so disabling capture would leave no
          trace of itself. EventSubscriber ignores an unregistered action, which
          means the gap in your audit log would be the only evidence that anything
          was turned off.

          Add both of these to config/initializers/audit_log.rb, inside the
          to_prepare block that calls AuditLog::Registry.clear!:

            AuditLog::Registry.register "#{DISABLED_ACTION}",
              requires: %i[reason],
              description: "Layer 1 trigger capture was disabled.",
              summary: ->(p) { "Audit capture disabled: " + p[:reason].to_s }

            AuditLog::Registry.register "#{RESUMED_ACTION}",
              description: "Layer 1 trigger capture was resumed.",
              summary: ->(p) { "Audit capture resumed, disabled since " + p[:disabled_at].to_s }

          `rails generate audit_log:install` writes both for a new application.
        MESSAGE
      end

      # ------------------------------------------------------------- the marker
      def disabled?(connection: ActiveRecord::Base.connection)
        !status(connection: connection).nil?
      end

      # The marker's payload, or nil. Parsed rather than returned raw so a caller
      # never has to know the encoding -- and a marker that will not parse is
      # reported as present with no detail rather than crashing a coverage report,
      # the same way an unreadable RETIRED_MARKER is skipped rather than guessed at.
      def status(connection: ActiveRecord::Base.connection)
        comment = connection.select_value(<<~SQL)
          SELECT obj_description(c.oid, 'pg_class')
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  c.relname = #{connection.quote(MARKED_TABLE)}
            AND  n.nspname = current_schema()
        SQL

        return nil unless comment.to_s.start_with?(MARKER)

        JSON.parse(comment.to_s.sub(/\A#{Regexp.escape(MARKER)}\s*/, "").presence || "{}")
      rescue JSON::ParserError
        {}
      end

      def mark!(reason:, snapshot:, connection: ActiveRecord::Base.connection)
        payload = {
          reason:      reason,
          disabled_at: Time.now.utc.iso8601,
          triggers:    snapshot
        }.to_json

        connection.execute(
          "COMMENT ON TABLE #{connection.quote_table_name(MARKED_TABLE)} IS " \
          "#{connection.quote("#{MARKER} #{payload}")}"
        )
      end

      def clear_marker!(connection: ActiveRecord::Base.connection)
        connection.execute(
          "COMMENT ON TABLE #{connection.quote_table_name(MARKED_TABLE)} IS NULL"
        )
      end

      # What the triggers were, per the marker -- the recovery path when the
      # migration that holds the same list is gone. Empty when capture is not
      # disabled, and empty (rather than a guess) when the marker will not parse:
      # `audit_log:enable` refuses on an empty snapshot instead of reconstructing
      # one from table names.
      def snapshot(connection: ActiveRecord::Base.connection)
        Array(status(connection: connection)&.dig("triggers")).map do |t|
          {
            table:      t["table"],
            model:      t["model"],
            excluded:   Array(t["excluded"]),
            dimensions: Array(t["dimensions"])
          }
        end
      end

      private

      # Stored with string keys and only the four fields that reproduce an
      # attach. `trigger:` is deliberately not among them -- the name is derived
      # from the table by `trigger_name`, so storing it would be a second place
      # for it to disagree.
      #
      # `:excluded` OR `:exclude`, because the two callers spell it differently
      # for good reasons and neither should have to translate: `attached` returns
      # `:excluded`, which is what the catalog holds, and the generated migration
      # writes `:exclude`, which is what `attach_audit_trigger` takes. Accepting
      # one and silently ignoring the other stores an empty exclusion list, and
      # the marker then reads as "this table excluded nothing" -- a snapshot that
      # restores MORE columns than the original captured, discovered only by
      # somebody comparing diffs years later.
      def normalize(trigger)
        t = trigger.symbolize_keys
        excluded = t.key?(:excluded) ? t[:excluded] : t[:exclude]

        {
          "table"      => t[:table].to_s,
          "model"      => t[:model].to_s,
          "excluded"   => Array(excluded).map(&:to_s),
          "dimensions" => Array(t[:dimensions]).map(&:to_s)
        }
      end

      def split_list(value)
        value.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
