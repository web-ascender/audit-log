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

      return stream_csv(AuditLog::CsvExport.for(csv_scope),
                        "audit-#{@record_type}-#{@record_id}-#{@view}") if request.format.csv?

      @pagy = paginate(paginated_scope)
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
        @entries        = record_timeline.entries(@pagy.records)
        @timeline_scope = record_timeline
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
        record_type: @record_type, record_id: @record_id,
        range: timeline_range, labels: @audit_labels
      )
    end

    # UNBOUNDED by default, like the rest of Screen A: a single record has
    # bounded history, and a bound nobody asked for is invisible truncation.
    #
    # `?days=` is an opt-in fast path for a hot record, and it exists here mainly
    # so the engine exercises BOTH states -- a disclosure that never renders is a
    # disclosure nobody has tested. Closed at the top on purpose; see
    # Timeline#window for the 3x that costs nothing.
    def timeline_range
      days = params[:days].to_i
      return nil unless days.positive?

      days.clamp(1, 3_650).days.ago..Time.current
    end

    def timeline
      @timeline ||= AuditLog::RecordTimeline.new(
        record_type: @record_type, record_id: @record_id
      )
    end

    # What the screen PAGES. For the timeline that is the union spine -- one row
    # per unit of work -- which is not a row of either audit table and is not
    # what the export ships. See csv_scope.
    def paginated_scope
      return timeline.events if @view == "actions"
      return record_timeline.spine if @view == "timeline"

      record_changes
    end

    # What the screen EXPORTS, which is not always what it pages.
    #
    # The CSV is the evidence artifact, and DESIGN §11.4a is why it ships
    # recorded rows: the actions tab exports the subject-matched events only,
    # because the correlated section below it is a capped inference; the timeline
    # tab exports the record's CHANGE ROWS, because a spine row is a derived
    # grouping this library invented and not something the database recorded. An
    # export that shipped either one would be claiming more than the log holds.
    def csv_scope
      return timeline.events if @view == "actions"

      record_changes
    end

    def record_changes
      AuditLog::RecordHistory.new(
        record_type: @record_type, record_id: @record_id
      ).changes
    end
  end
end
