# frozen_string_literal: true

require "csv"

module AuditLog
  # Streaming CSV for the auditor screens. ROLLOUT Q6.
  #
  # Two properties an audit export has to have, and neither is free:
  #
  #   1. **It is complete.** The screens page precisely so they never truncate
  #      silently; an export that quietly stopped at 10,000 rows would put the
  #      failure straight back. So there is no row cap here -- the bound is the
  #      screen's date range, which the caller has already applied.
  #   2. **It does not materialise.** A month of audit_changes is not something to
  #      build in memory as one String and hand to send_data. Rows are fetched in
  #      batches and yielded as they are formatted.
  #
  # Batching walks the same (occurred_at, id) keyset the screens page by, rather
  # than in_batches: in_batches orders by primary key and would silently discard
  # the ORDER BY, so the export would come out in a different order from the
  # screen it was taken from. Row-value comparison keeps it index-friendly and
  # keeps the caller's date predicate intact, so partitions still prune.
  class CsvExport
    include Enumerable

    BATCH = 1_000

    # `dimensions` ships on both, because it is RECORDED data rather than a
    # display-time annotation -- the distinction that keeps association labels out
    # of this export. A facet is what the trigger read off the row, or what the
    # action declared; it is exactly the kind of thing an auditor needs in the
    # evidence artifact to explain why a row appeared in a filtered view.
    CHANGE_COLUMNS = %w[
      occurred_at record_type record_id operation changed_columns diff
      actor_type actor_id actor_label request_id dimensions
    ].freeze

    EVENT_COLUMNS = %w[
      occurred_at action summary actor_type actor_id actor_label
      subject_type subject_id source ip request_id caused_by_request_id metadata
      dimensions
    ].freeze

    def self.for(scope)
      columns = scope.model <= AuditLog::Event ? EVENT_COLUMNS : CHANGE_COLUMNS
      new(scope, columns: columns)
    end

    def initialize(scope, columns:, batch: BATCH)
      @scope   = scope
      @columns = columns
      @batch   = batch
    end

    # Yields CSV lines, header first. Enumerable, so a controller can hand it
    # straight to response_body and Rack will pull from it.
    def each(&block)
      return to_enum(:each) unless block

      yield CSV.generate_line(@columns)
      each_row { |record| yield CSV.generate_line(@columns.map { |c| cell(record, c) }) }
    end

    def filename(prefix)
      "#{prefix}-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}.csv"
    end

    private

    def each_row
      cursor = nil

      loop do
        rel = @scope.reorder(occurred_at: :desc, id: :desc).limit(@batch)
        # Row-value comparison: exactly the keyset the screens page by, and the
        # tuple form is what lets Postgres treat it as a range rather than as
        # three unrelated predicates.
        rel = rel.where("(audit_#{table}.occurred_at, audit_#{table}.id) < (?, ?)", *cursor) if cursor

        rows = rel.to_a
        break if rows.empty?

        rows.each { |r| yield r }
        break if rows.size < @batch

        cursor = [rows.last.occurred_at, rows.last.id]
      end
    end

    def table
      @scope.model <= AuditLog::Event ? "events" : "changes"
    end

    # jsonb and text[] go out as their JSON form rather than Ruby's inspect
    # output, so the file is machine-readable by whatever the auditor uses next.
    def cell(record, column)
      value = record.public_send(column)

      case value
      when nil          then nil
      when Hash, Array  then value.to_json
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
      else value.to_s
      end
    end
  end
end
