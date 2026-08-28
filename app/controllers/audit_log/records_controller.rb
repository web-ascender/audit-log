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
    #
    # Two tabs over the two layers, mirroring the actor screen, and for the same
    # reason: the narrative is what a human reads and the change rows are what
    # survives an unregistered write path. Neither is a substitute for the other,
    # so neither is hidden behind the other.
    def history
      @record_type = params[:record_type]
      @record_id   = params[:record_id]
      @view        = params[:view] == "actions" ? "actions" : "changes"

      scope = view_scope
      return stream_csv(AuditLog::CsvExport.for(scope),
                        "audit-#{@record_type}-#{@record_id}-#{@view}") if request.format.csv?

      @pagy = paginate(scope)
      if @view == "actions"
        @events             = @pagy.records
        @changes_by_request = timeline.changes_for(@events)
        @correlated         = timeline.correlated(limit: correlation_scan)
      else
        @changes = @pagy.records
      end
    end

    private

    # How much of the record's change history the correlated section reads. The
    # default is one page; the screen offers to widen it, because a cap an
    # auditor cannot escape is a cap that under-reports. Clamped rather than
    # trusted -- this is a hand-editable URL parameter driving a row limit.
    CORRELATION_SCAN_MAX = 1_000

    def correlation_scan
      scan = params[:scan].to_i
      return nil if scan <= 0

      scan.clamp(1, CORRELATION_SCAN_MAX)
    end

    def timeline
      @timeline ||= AuditLog::RecordTimeline.new(
        record_type: @record_type, record_id: @record_id
      )
    end

    # The CSV is the evidence artifact for whichever tab is open. It carries the
    # SUBJECT-MATCHED events only -- the correlated section is a capped, inferred
    # reading aid, and an export that silently mixed the two would be claiming
    # more precision than the request_id link supports.
    def view_scope
      return timeline.events if @view == "actions"

      AuditLog::RecordHistory.new(
        record_type: @record_type, record_id: @record_id
      ).changes
    end
  end
end
