# frozen_string_literal: true

module AuditLog
  # Q2 -- "All modifications to this model: by whom, when, which fields?"
  class RecordsController < ApplicationController
    def index
      @record_types = AuditLog::Change.occurred_between(date_range.to_range)
                                      .group(:record_type)
                                      .order(count_all: :desc).count
    end

    # Screen B: every record of one class in a window, optionally narrowed to
    # specific fields.
    def show
      @record_type = params[:id]
      @columns     = Array(params[:columns]).reject(&:blank?)

      query = AuditLog::RecordHistory.new(
        record_type: @record_type, range: date_range.to_range, columns: @columns
      )
      return stream_csv(AuditLog::CsvExport.for(query.changes), "audit-#{@record_type}") if
        request.format.csv?

      @pagy            = paginate(query.changes)
      @changes         = @pagy.records
      @touched_columns = query.touched_columns
    end

    # Screen A: one record's full history. The one screen where an unbounded
    # range is acceptable -- a single record has bounded history.
    def history
      @record_type = params[:record_type]
      @record_id   = params[:record_id]

      scope = AuditLog::RecordHistory.new(
        record_type: @record_type, record_id: @record_id
      ).changes
      return stream_csv(AuditLog::CsvExport.for(scope), "audit-#{@record_type}-#{@record_id}") if
        request.format.csv?

      @pagy    = paginate(scope)
      @changes = @pagy.records
    end
  end
end
