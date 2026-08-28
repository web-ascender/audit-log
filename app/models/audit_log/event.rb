# frozen_string_literal: true

module AuditLog
  # Layer 2: one row per business action. This is what an auditor reads.
  class Event < Record
    self.table_name = "audit_events"

    SOURCES = %w[web api job console system migration].freeze

    scope :occurred_between, ->(range) { where(occurred_at: range) }
    scope :by_actor, ->(type, id) { where(actor_type: type, actor_id: id) }
    scope :for_action, ->(action) { where(action: action) }
    scope :for_subject, ->(type, id) { where(subject_type: type, subject_id: id) }
    scope :newest_first, -> { order(occurred_at: :desc, id: :desc) }

    # The change rows produced by the same user action. Not a Rails association:
    # request_id is not a foreign key, and the query must stay date-bounded or the
    # planner cannot eliminate a single partition.
    #
    # This is the EXACT-anchor case: an event knows its own occurred_at, so the
    # bound costs nothing and infers nothing. RequestDrillDown explains why the
    # bound is needed and what happens when no anchor is available.
    def drill_down(slack: nil)
      AuditLog::RequestDrillDown.new(request_id, anchor: occurred_at, slack: slack)
    end

    def changes_in_request(slack: nil)
      drill_down(slack: slack).changes
    end

    def actor_display
      actor_label.presence || (actor_type ? "#{actor_type} ##{actor_id}" : "System")
    end
  end
end
