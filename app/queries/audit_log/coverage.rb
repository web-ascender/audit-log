# frozen_string_literal: true

module AuditLog
  # "Has every table been decided about?"
  #
  # Layer 1 is opt-in per table -- one attach_audit_trigger line in a migration --
  # and that is deliberate: auditing every table automatically sweeps in queue,
  # cache and session tables whose churn buries real findings. The risk of opt-in
  # is that a table gets added and nobody decides. This is the forcing function
  # that makes deciding mandatory, and it reads pg_trigger rather than the
  # migration history, so it cannot be satisfied by a migration that looks right.
  #
  # ONE definition, used by both `rake audit_log:coverage` and the shared example
  # in audit_log/rspec. It used to be spelled twice -- once in the rake task and
  # once in the host app's copied spec -- and the two could disagree about what
  # counted as covered, which for a forcing function is the whole ballgame.
  class Coverage
    # ActiveRecord::Base, NOT ApplicationRecord. The rake task named the latter,
    # which is a host application constant inside the library -- the one coupling
    # this design does not permit. Base resolves to the primary connection in
    # exactly the same way, including when a queue or cache database is attached
    # through connects_to on a different abstract class.
    def initialize(connection: ActiveRecord::Base.connection)
      @connection = connection
    end

    # Tables with an audit trigger actually attached, per the catalog.
    #
    # SCOPED TO current_schema(), which is the schema `@connection.tables` below
    # reports on -- the two halves of the subtraction in `missing` have to be
    # asking about the same schema or the answer is meaningless. Unscoped, a
    # database holding the same table in several schemas lets one schema's
    # trigger vouch for another schema's table, and coverage passes while a
    # table goes unaudited. That is the exact failure this class exists to
    # prevent, arrived at through the class itself.
    def audited_tables
      @audited_tables ||= @connection.select_values(<<~SQL)
        SELECT c.relname
        FROM   pg_trigger t
        JOIN   pg_class c ON c.oid = t.tgrelid
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  NOT t.tgisinternal
          AND  t.tgname LIKE '%\\_audit'
          AND  n.nspname = current_schema()
      SQL
    end

    # Partitions inherit their parent's triggers and cannot be attached
    # independently, so they are never candidates. Excluded here rather than
    # listed in unaudited_tables, which keeps that list about DECISIONS instead of
    # about partition rotation.
    def partition_tables
      @partition_tables ||= @connection.select_values(<<~SQL)
        SELECT c.relname
        FROM   pg_class c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        JOIN   pg_inherits i ON i.inhrelid = c.oid
        WHERE  n.nspname = current_schema()
      SQL
    end

    def exempt_tables = AuditLog.config.unaudited_tables.keys

    # THE THIRD STATE: capture deliberately disabled, per the marker
    # AuditLog::Capture stamps. DESIGN §25.
    #
    # Without this, a disabled audit log fails coverage with "23 untracked tables:
    # orders, products, ... Add attach_audit_trigger to a migration" -- which is
    # true, useless, and actively misleading. It sends somebody to re-attach one
    # table at a time, and `rails generate audit_log:trigger orders` SUCCEEDS
    # while it is disabled (attach only collides with an existing trigger, and
    # there is none), so the repair half-works and the marker is left standing
    # over a schema that no longer matches it.
    #
    # It does NOT make the report pass. A disabled audit log must never come back
    # OK, for the reason `retention_action` was removed: an option that lets a
    # forcing function be satisfied while the thing it forces is switched off is
    # weaker than no option. What this changes is only what the failure SAYS.
    def capture_disabled? = !capture_marker.nil?

    def capture_marker
      return @capture_marker if defined?(@capture_marker)

      @capture_marker = AuditLog::Capture.status(connection: @connection)
    end

    # The finding: a table that is neither audited nor exempted.
    #
    # SORTED, because `@connection.tables` comes back in catalog order -- roughly
    # the order the tables were created, which is information nobody reading this
    # list is using. Somebody scanning forty names for the one they just added,
    # or diffing two CI runs, wants them alphabetical.
    def missing
      (@connection.tables - audited_tables - exempt_tables - partition_tables).sort
    end

    # An exemption for a table that has since been dropped. Not cosmetic -- a
    # stale entry silently re-exempts a NEW table that later reuses the name.
    def stale_exemptions
      exempt_tables - @connection.tables
    end

    # An exemption with no written reason is not a decision, it is a shrug.
    def unreasoned_exemptions
      AuditLog.config.unaudited_tables.reject { |_, reason| reason.to_s.strip.presence }.keys
    end

    def audits_the_audit_tables?
      audited_tables.intersect?(%w[audit_changes audit_events])
    end

    def ok?
      !capture_disabled? && missing.empty? && stale_exemptions.empty? &&
        unreasoned_exemptions.empty? && !audits_the_audit_tables?
    end

    # For the rake task and for a spec failure message.
    def report
      return "OK: every table is either audited or explicitly exempted." if ok?

      lines = []

      if capture_disabled?
        lines << "CAPTURE IS DISABLED. Layer 1 is writing nothing."
        lines << "  disabled at: #{capture_marker["disabled_at"] || "(unrecorded)"}"
        lines << "  reason:      #{capture_marker["reason"] || "(unrecorded)"}"
        lines << "  tables:      #{Array(capture_marker["triggers"]).size} detached"
        lines << "  now untracked: #{missing.size} - #{missing.join(", ")}" if missing.any?
        lines << ""
        lines << "  This is a deliberate state, not a missing migration, so those tables"
        lines << "  need no attach_audit_trigger -- they need capture resumed:"
        lines << "    rails db:migrate:down VERSION=<the audit_log:disable migration>"
        lines << "  or `rails generate audit_log:enable` if that migration is gone."
        lines << ""
        lines << "  It fails anyway, on purpose. A disabled audit log is not OK, and"
        lines << "  the honest options are to resume capture or to accept a red check"
        lines << "  for as long as the pause lasts. Do not skip the spec."
      elsif missing.any?
        # The count leads, because the list is the part that scrolls: a CI log
        # showing the tail of a forty-table wall reads as a handful of findings.
        lines << "#{missing.size} untracked #{"table".pluralize(missing.size)}: #{missing.join(", ")}"
        lines << "  Add attach_audit_trigger to a migration, or add the table to"
        lines << "  AuditLog.config.unaudited_tables with a written reason."
      end
      lines << "Exempted but nonexistent: #{stale_exemptions.join(", ")}" if stale_exemptions.any?
      lines << "Exempted with no reason: #{unreasoned_exemptions.join(", ")}" if unreasoned_exemptions.any?
      lines << "The audit tables are themselves audited, which recurses." if audits_the_audit_tables?
      lines.join("\n")
    end
  end
end
