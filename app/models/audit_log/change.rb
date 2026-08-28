# frozen_string_literal: true

module AuditLog
  # Layer 1: one row per row-level change, written by the database trigger.
  #
  # This table is COMPLETE in a way audit_events is not: audit_events only holds
  # actions someone remembered to register, whereas every INSERT, UPDATE and
  # DELETE on an audited table lands here regardless of how it was issued.
  class Change < Record
    self.table_name = "audit_changes"

    INSERT = "I"
    UPDATE = "U"
    DELETE = "D"

    OPERATION_NAMES = { INSERT => "Created", UPDATE => "Updated", DELETE => "Deleted" }.freeze

    scope :occurred_between, ->(range) { where(occurred_at: range) }
    scope :by_actor, ->(type, id) { where(actor_type: type, actor_id: id) }
    scope :for_record, ->(type, id) { where(record_type: type, record_id: id) }
    scope :for_type, ->(type) { where(record_type: type) }
    scope :newest_first, -> { order(occurred_at: :desc, id: :desc) }
    scope :modifications, -> { where(operation: [UPDATE, DELETE]) }

    # Uncorrelated writes: a console session, a migration, a manual psql
    # connection. The highest-scrutiny rows in the log, so they get a named scope
    # and their own screen rather than being hidden.
    scope :out_of_band, -> { where(request_id: nil) }

    # Served by the GIN index on changed_columns.
    #
    # The intuitive query is `diff ? 'status'` and it has two independent traps.
    # First, `?` is a bind placeholder in ActiveRecord, so the jsonb operator has
    # to be written `??` or as jsonb_exists(). Second, and silently: a GIN index
    # built with jsonb_path_ops does not support `?` AT ALL, so the planner drops
    # to a sequential scan and nothing warns you.
    scope :touching_columns, ->(*cols) {
      where("changed_columns && ARRAY[?]::text[]", cols.flatten.map(&:to_s))
    }

    def operation_name
      OPERATION_NAMES.fetch(operation, operation)
    end

    def created?  = operation == INSERT
    def updated?  = operation == UPDATE
    def deleted?  = operation == DELETE

    def out_of_band? = request_id.nil?

    def actor_display
      AuditLog::ActorLabel.display(actor_type, actor_id, actor_label)
    end

    # [[column, old, new], ...] sorted for stable rendering.
    def field_changes
      diff.map { |col, (old_value, new_value)| [col, old_value, new_value] }
          .sort_by { |col, _, _| col }
    end

    def label
      "#{record_type} ##{record_id}"
    end

    # The change rows produced by a PAGE of events, grouped by request_id, in one
    # query rather than N. This is what turns a 40-record nested-attributes save
    # into ONE expandable row instead of 40 the auditor has to reassemble.
    #
    # THE DATE BOUND IS NOT OPTIONAL, for the reason AuditLog::RequestDrillDown
    # exists to explain: `WHERE request_id IN (...)` mentions occurred_at not at
    # all, so partition elimination is syntactically impossible and the query
    # touches every partition -- six today, 84 at a 7-year horizon, on every page
    # render of every screen that drills down. The events being expanded carry
    # their own occurred_at, so the bound costs nothing and infers nothing.
    #
    # The window is the page's own span widened by drill_down_slack on each side,
    # which is strictly more generous than the +/-slack RequestDrillDown applies
    # to a single event. A change row escapes it only by sharing a request_id
    # with an event on this page while occurring more than a day from every event
    # on it -- and a request_id's lifetime is one request or one job execution,
    # because jobs deliberately do not inherit their enqueuer's id (plan 6.4).
    def self.grouped_by_request(events, slack: nil)
      events = Array(events)
      return {} if events.empty?

      scope = where(request_id: events.filter_map(&:request_id).uniq)
      times = events.filter_map(&:occurred_at)
      if times.any?
        slack ||= AuditLog.config.drill_down_slack
        scope = scope.where(occurred_at: (times.min - slack)..(times.max + slack))
      end

      scope.order(:occurred_at, :id).group_by(&:request_id)
    end
  end
end
