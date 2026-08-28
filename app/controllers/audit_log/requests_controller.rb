# frozen_string_literal: true

module AuditLog
  # Drill-down: one user action, and every row it touched.
  class RequestsController < ApplicationController
    def show
      @request_id = params[:id]

      # No event in hand here -- the id arrives as a URL parameter -- so the bound
      # comes from the UUIDv7 itself. `?full=1` drops it for an auditor who wants
      # certainty over speed; see RequestDrillDown for why either exists.
      @drill_down = AuditLog::RequestDrillDown.new(
        @request_id, bounded: params[:full].blank?
      )
      @events  = @drill_down.events
      @changes = @drill_down.changes

      # Follow the causal chain in both directions. The cause is one indexed
      # lookup on request_id, anchored exactly once we have the event in hand.
      cause_id = @events.first&.caused_by_request_id
      @cause = cause_id && AuditLog::RequestDrillDown.new(cause_id).events.first

      @caused = @drill_down.caused_events
    end
  end
end
