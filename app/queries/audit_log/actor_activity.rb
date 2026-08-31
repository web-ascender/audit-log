# frozen_string_literal: true

module AuditLog
  # Q1 -- "What did Jane Doe modify or delete last week? Or on a specific date?"
  #
  # Deliberately exposes TWO views, and the screen shows both:
  #
  #   events  -- the narrative. Readable, but complete only for actions someone
  #              remembered to put in the Registry.
  #   changes -- the record layer. Complete by construction, independent of the
  #              registry, and the compliance-grade answer to "modify or delete".
  #
  # Building an actor timeline off events alone is the trap: a change made
  # through a path that never emitted a registered action exists in audit_changes
  # and nowhere else. Reconciler keeps that gap visible and shrinking.
  class ActorActivity
    attr_reader :actor_type, :actor_id, :range

    def initialize(actor: nil, actor_type: nil, actor_id: nil, range:)
      @actor_type = actor ? actor.class.name : actor_type
      @actor_id   = actor ? actor.id : actor_id
      @range      = range
    end

    def events
      AuditLog::Event.by_actor(actor_type, actor_id)
                     .occurred_between(range)
                     .newest_first
    end

    def changes(operations: nil)
      scope = AuditLog::Change.by_actor(actor_type, actor_id)
                              .occurred_between(range)
                              .newest_first
      operations.present? ? scope.where(operation: operations) : scope
    end

    # Drill-down for one page of events, without an N+1: one indexed query on
    # request_id for the whole page. This is where the design pays off -- a
    # 40-record nested-attributes form submit renders as ONE expandable row, not
    # 40 rows the auditor has to mentally reassemble.
    #
    # Delegated so this screen and the record timeline cannot drift about what
    # "the changes behind this page of events" means -- and so both get the date
    # bound. This query used to carry none, which made it the one drill-down in
    # the library that scanned every partition; Change.grouped_by_request says
    # why that matters and where the window comes from.
    def changes_for(events)
      AuditLog::Change.grouped_by_request(events)
    end
  end
end
