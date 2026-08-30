# frozen_string_literal: true

module AuditLog
  # Q1 -- "What did Jane Doe modify or delete last week?"
  class ActorsController < ApplicationController
    def index
      # The actor picker is sourced from the actor table, NOT from the audit log:
      # an auditor searching for "Jane Doe" wants to find her whether or not she
      # has activity in the current window, and SELECT DISTINCT actor_id over
      # audit_changes would be unusable at volume.
      @actors = AuditLog.config.actor_picker.call(params[:q])
    end

    def show
      @actor_type = params[:actor_type].presence || "User"
      @actor_id   = params[:id]
      @view       = params[:view] == "changes" ? "changes" : "actions"

      @query = AuditLog::ActorActivity.new(
        actor_type: @actor_type, actor_id: @actor_id, range: date_range.to_range
      )

      if request.format.csv?
        scope = @view == "actions" ? @query.events : @query.changes(operations: %w[I U D])
        return stream_csv(AuditLog::CsvExport.for(scope), "audit-actor-#{@actor_id}-#{@view}")
      end

      if @view == "actions"
        @page    = paginate(@query.events)
        @events  = @page.records
        @changes = @query.changes_for(@events)
      else
        @operations = Array(params[:operations]).presence || %w[I U D]
        @page       = paginate(@query.changes(operations: @operations))
        @records    = @page.records
      end

      # Prefer the SNAPSHOT the audit rows carry over the live record: it is what
      # the actor was called when they acted. The live lookup is only a fallback
      # for an actor with no activity in this window.
      @actor_label = (@events || @records).first&.actor_display ||
        AuditLog::ActorLabel.for(AuditLog.config.actor_finder.call(@actor_type, @actor_id)) ||
        "#{@actor_type} ##{@actor_id}"
    end
  end
end
