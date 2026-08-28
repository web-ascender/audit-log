# frozen_string_literal: true

module AuditLog
  # Keeps the narrative layer honest about how much of the record layer it covers.
  #
  # Every hit is a mutation path with no entry in the Registry. Run it daily and
  # alert when non-empty; the list should trend to zero.
  class Reconciler
    Row = Struct.new(:request_id, :occurred_at, :change_count, :record_types, keyword_init: true)

    def initialize(range: 1.day.ago..Time.current, lookback: 2.days)
      @range    = range
      @lookback = lookback
    end

    def uncovered_requests
      sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, @lookback.ago, @range.begin, @range.end])
        SELECT c.request_id,
               min(c.occurred_at)              AS occurred_at,
               count(*)                        AS change_count,
               array_agg(DISTINCT c.record_type) AS record_types
        FROM   audit_changes c
        LEFT   JOIN audit_events e
               ON  e.request_id  = c.request_id
               AND e.occurred_at >= ?
        WHERE  c.occurred_at BETWEEN ? AND ?
          AND  c.request_id IS NOT NULL
          AND  e.id IS NULL
        GROUP  BY c.request_id
        ORDER  BY min(c.occurred_at) DESC
      SQL

      ActiveRecord::Base.connection.select_all(sql).map do |r|
        Row.new(
          request_id: r["request_id"],
          occurred_at: r["occurred_at"],
          change_count: r["change_count"].to_i,
          record_types: parse_array(r["record_types"])
        )
      end
    end

    private

    def parse_array(value)
      return value if value.is_a?(Array)
      value.to_s.delete("{}").split(",").reject(&:empty?)
    end
  end
end
