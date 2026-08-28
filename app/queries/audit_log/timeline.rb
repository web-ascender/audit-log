# frozen_string_literal: true

module AuditLog
  # "Show me everything that happened to this order, the way a person would tell
  # it." The host-app-facing surface: a paginated list of UNITS OF WORK, each one
  # carrying its narrative, this record's own field changes, and the other
  # records the same action touched.
  #
  # WHY VALUE OBJECTS RATHER THAN RELATIONS. The auditor UI encodes rules that
  # are invisible from outside the gem -- that a diff value's three nil shapes
  # mean different things, that a nil actor renders "System" but is never stored
  # that way, that a redacted payload and an absent one are the same empty jsonb
  # and only the marker separates them, that an association label annotates a
  # recorded id and must never replace it. Ship the relations alone and every
  # host app re-derives those, and some get them wrong on a screen that looks
  # fine. The value objects make each rule a method call.
  #
  # THE SPINE IS A UNION OVER BOTH TABLES ("Spine B"), keyed on the unit of work.
  # An entry belongs on this record's timeline for either of two reasons, and
  # both are real:
  #
  #   the unit WROTE this record   -- an audit_changes row. Complete by
  #                                   construction, whatever path the write took.
  #   the unit was ABOUT it        -- an audit_events row whose subject is this
  #                                   record, even when it wrote nothing here.
  #
  # The second leg is not a nicety. Without it the timeline silently drops: an
  # action that wrote only children (adding a line item, where the order row
  # itself never changes), an action whose write landed in another table
  # (order.emailed -> deliveries), an action that wrote nothing at all
  # (order.exported), and EVERY action on a record whose table is in
  # config.unaudited_tables -- which has no trigger, so no change rows exist and
  # a changes-only spine renders an empty page. DESIGN §11.2b.
  #
  # WHAT IT STILL DOES NOT REACH, stated rather than discovered: an UNREGISTERED
  # action that only wrote children. No event, because nobody registered one, and
  # no change row for this record, because nothing here changed. Finding it would
  # mean walking a child's change rows back to their parent -- which works on an
  # insert or a delete, where the whole row is in the diff, and fails on an update,
  # where only the changed columns are, so `order_id` is usually absent. Closing
  # that gap needs a live join to the child's business table, and joining to
  # business tables is what stops these screens being truthful about deleted
  # records. It is a registry gap, and `rake audit_log:reconcile` is the tool that
  # reports it.
  #
  # ONE SPINE ROW IS ONE ENTRY, which is why there is no page-boundary rule here.
  # An earlier changes-only spine paged over change ROWS and grouped them, so one
  # unit of work could straddle a cursor and needed a de-duplication pass; keying
  # the spine on the unit itself deletes that problem rather than managing it.
  class Timeline
    attr_reader :record_type, :record_id, :range, :labels

    # Takes the host's own record. The only place this library touches an
    # application object: it reads `.class.name` and `.id` and keeps neither.
    def self.for(record, **kwargs)
      new(record_type: record.class.name, record_id: record.id, **kwargs)
    end

    # range: bounds BOTH legs and is the single biggest lever on cost. Measured
    # against a 36-month horizon (72 monthly partitions across the two tables):
    #
    #   unbounded ................................. 72 partitions in the plan
    #   range: 1.year.ago..Time.current ........... 34
    #   range: 90.days.ago..Time.current .......... 16
    #   range: 30.days.ago..Time.current ...........  4
    #
    # Default nil, and deliberately no config-level default: a bound nobody asked
    # for is invisible truncation, which is the failure this library exists to
    # prevent. RequestDrillDown says it first -- a bound that under-reports is
    # worse than a slow query. A caller opts in where the opting is visible, and
    # `bounded?` / `scope_description` exist so the screen can say so.
    def initialize(record_type:, record_id:, range: nil, labels: nil)
      @record_type = record_type
      @record_id   = record_id
      @range       = range
      @labels      = labels || AuditLog::LabelResolver.new
    end

    # The spine, as an ORDERED, UNLIMITED relation: the caller paginates it and
    # hands the page to #entries. Two calls rather than one because a limit
    # applied below the controller is invisible to the screen rendering it --
    # DESIGN §11.0 Rule 2.
    #
    # Order through arel_table on BOTH columns; see SpineRow for why
    # `order(uow: :desc)` breaks Pagy.
    def spine
      SpineRow
        .from(Arel.sql("(#{spine_sql}) AS #{SpineRow.table_name}"))
        .select("uow", "occurred_at")
        .order(SpineRow.arel_table[:occurred_at].desc, SpineRow.arel_table[:uow].desc)
    end

    # A page of spine rows -> [Entry], newest first.
    #
    # Four queries for the whole page regardless of its size: the change rows of
    # every correlated unit on the page, its events, the out-of-band rows, and one
    # label warm. The correlated hydrations are date-bounded off the page's own
    # rows (Record.grouped_by_request), so they prune too.
    def entries(page)
      rows = Array(page)
      return [] if rows.empty?

      correlated, out_of_band = rows.partition { |row| !row.out_of_band? }

      changes    = AuditLog::Change.grouped_by_request(correlated)
      events     = AuditLog::Event.grouped_by_request(correlated)
      loose      = out_of_band_changes(out_of_band)
      labels.warm(changes.values.flatten + loose.values)

      rows.map do |row|
        related = row.out_of_band? ? Array(loose[row.change_id]) : Array(changes[row.request_id])
        build(row, related, row.out_of_band? ? [] : Array(events[row.request_id]))
      end
    end

    def bounded? = !range.nil?

    # For a screen: a narrowed timeline must never look like a complete one.
    def scope_description
      return "across all retained history" unless bounded?

      from, to = window.first, window.last
      "from #{from.to_date.iso8601} to #{to.to_date.iso8601}"
    end

    # OPT-IN, and never called from #entries. It answers "is there history older
    # than this window?" -- the difference between "end of results" and "end of
    # the window" -- with one indexed existence check per table.
    #
    # It is opt-in precisely BECAUSE it looks below range.begin, which is the one
    # thing the bound exists to avoid: calling it on every page would hand back
    # the partition pruning the caller just bought. Call it once, at the bottom of
    # the last page, when the distinction is worth a query.
    def older_than_window?
      return false unless bounded? && window.first

      before = ...window.first
      AuditLog::Change.for_record(record_type, record_id).where(occurred_at: before).exists? ||
        AuditLog::Event.for_subject(record_type, record_id).where(occurred_at: before).exists?
    end

    # An endless range is CLOSED at the current instant, and that loses nothing:
    # occurred_at is filled by the column DEFAULT clock_timestamp() and neither
    # layer ever supplies it from Ruby (asserted by utc_storage_spec), so no row
    # can carry a future timestamp. It is worth 3x -- `30.days.ago..` leaves every
    # months-ahead partition and the default partition in the plan (12), while
    # `30.days.ago..Time.current` prunes to 4.
    def window
      return nil unless bounded?

      [range.begin, range.end || Time.current]
    end

    private

    # Bind Ruby TIMES, never a SQL expression. `now() - interval '30 days'`
    # prunes at RUN time -- the planner keeps all 72 subplans and the executor
    # discards 60 -- while a bound timestamp prunes at PLAN time, which is where
    # the relation locks and opens are. Measured; do not "simplify" these binds
    # into SQL.
    def spine_sql
      AuditLog::Change.sanitize_sql_array([<<~SQL, record_type, record_id, record_type, record_id])
        SELECT uow, max(occurred_at) AS occurred_at FROM (
          SELECT COALESCE(request_id::text, '#{SpineRow::OOB_PREFIX}' || id) AS uow, occurred_at
            FROM audit_changes
           WHERE record_type = ?::text AND record_id = ?::bigint#{bound_sql}
          UNION ALL
          SELECT request_id::text AS uow, occurred_at
            FROM audit_events
           WHERE subject_type = ?::text AND subject_id = ?::bigint#{bound_sql}
        ) legs
        GROUP BY uow
      SQL
    end

    # Applied INSIDE each leg. On the outer aggregate it would prune nothing --
    # the planner cannot push a predicate on max(occurred_at) back through a
    # GROUP BY.
    def bound_sql
      return "" unless bounded?

      from, to = window
      AuditLog::Change.sanitize_sql_array(
        [" AND occurred_at >= ? AND occurred_at <= ?", from, to]
      )
    end

    # Out-of-band rows carry request_id IS NULL and correlate to nothing, so they
    # are fetched by id. Bounded off the page for the same reason everything else
    # is.
    def out_of_band_changes(rows)
      return {} if rows.empty?

      scope = AuditLog::Change.where(id: rows.map(&:change_id))
      times = rows.filter_map(&:occurred_at)
      if times.any?
        slack = AuditLog.config.drill_down_slack
        scope = scope.where(occurred_at: (times.min - slack)..(times.max + slack))
      end
      scope.index_by(&:id)
    end

    def build(row, related, events)
      mine = related.select do |change|
        change.record_type == record_type && change.record_id.to_s == record_id.to_s
      end

      entry = Entry.new(
        record_type: record_type, record_id: record_id,
        request_id: row.request_id,
        # From the SPINE, not from `mine`: an entry can legitimately have no
        # change rows for this record at all -- that is the whole point of the
        # second leg -- and max() over an empty list is nil.
        occurred_at: row.occurred_at,
        events: events, changes: mine.sort_by(&:occurred_at), labels: labels
      )
      entry.also_touched = touched(related)
      entry
    end

    # The OTHER records the unit wrote, one per (type, id) rather than one per
    # change row: a save that writes the same row twice is still one record, and
    # an entry claiming otherwise inflates what happened.
    def touched(related)
      related
        .reject { |c| c.record_type == record_type && c.record_id.to_s == record_id.to_s }
        .group_by { |c| [c.record_type, c.record_id] }
        .map do |(type, id), rows|
          label = labels.for(type, id)
          TouchedRecord.new(
            type: type, id: id,
            operations: rows.map(&:operation).uniq,
            columns: rows.flat_map(&:changed_columns).uniq.sort,
            label: (label if label.is_a?(String)),
            label_failed: label == AuditLog::LabelResolver::FAILED
          )
        end
    end
  end
end
