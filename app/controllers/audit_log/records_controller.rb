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
      @view        = VIEWS.include?(params[:view]) ? params[:view] : "changes"

      scope = view_scope
      return stream_csv(AuditLog::CsvExport.for(scope),
                        "audit-#{@record_type}-#{@record_id}-#{@view}") if request.format.csv?

      @pagy = paginate(scope)
      case @view
      when "actions"
        @events             = @pagy.records
        @changes_by_request = timeline.changes_for(@events)
        @correlated         = timeline.correlated(limit: correlation_scan)
      when "timeline"
        # The engine renders the host-facing value objects rather than its own
        # relations, on purpose: this screen IS the test that the published
        # contract can build a real view. A presenter nothing in the gem consumes
        # drifts from what the auditor UI actually does -- the same argument that
        # makes Coverage back both the rake task and the shared example.
        @entries = record_timeline.entries(@pagy.records)
      else
        @changes = @pagy.records
      end
    end

    private

    VIEWS = %w[changes actions timeline].freeze

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

    # Shares ONE LabelResolver with the view. `audit_labels` is `@audit_labels
    # ||= LabelResolver.new` in the helper, and a view sees the controller's
    # ivars -- so seeding it here means the entries and anything else the page
    # renders resolve against one warmed cache rather than two.
    def record_timeline
      @audit_labels    ||= AuditLog::LabelResolver.new
      @record_timeline ||= AuditLog::Timeline.new(
        record_type: @record_type, record_id: @record_id, labels: @audit_labels
      )
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
      return record_timeline.changes if @view == "timeline"

      AuditLog::RecordHistory.new(
        record_type: @record_type, record_id: @record_id
      ).changes
    end
  end
end
