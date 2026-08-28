# frozen_string_literal: true

module AuditLog
  # Q3 -- "All order.submitted events, who triggered them, by date range."
  class ActionsController < ApplicationController
    def index
      @actions = AuditLog::Event.occurred_between(date_range.to_range)
                                .group(:action).order(count_all: :desc).count
      @registered = AuditLog::Registry.keys
    end

    def show
      @action = params[:id]
      report  = AuditLog::ActionReport.new(action: @action, range: date_range.to_range)

      return stream_csv(AuditLog::CsvExport.for(report.events), "audit-action-#{@action}") if
        request.format.csv?

      @pagy     = paginate(report.events)
      @events   = @pagy.records
      @by_actor = report.by_actor
      @entry    = AuditLog::Registry[@action]
    end
  end
end
