# frozen_string_literal: true

module AuditLog
  # Q3 -- "All order.submitted events, who triggered them, by date range."
  #
  # The easiest of the three: fully served by audit_events with no join at all,
  # because actor_label is already on the row. And because metadata holds the
  # full event payload, the screen can surface domain values (total_cents,
  # line_count) without touching the orders table -- which is what makes it still
  # work after the order has been deleted.
  class ActionReport
    attr_reader :action, :range

    def initialize(action:, range:)
      @action = action
      @range  = range
    end

    def events
      AuditLog::Event.for_action(action).occurred_between(range).newest_first
    end

    # Header rollup for the same screen.
    def by_actor
      AuditLog::Event.for_action(action)
                     .occurred_between(range)
                     .group(:actor_type, :actor_id, :actor_label)
                     .order(count_all: :desc)
                     .count
    end

    # The action picker needs no query at all: the registry is the authoritative
    # list and it is already in memory.
    def self.available_actions
      AuditLog::Registry.keys
    end
  end
end
