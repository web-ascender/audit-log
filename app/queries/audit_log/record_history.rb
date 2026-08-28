# frozen_string_literal: true

module AuditLog
  # Q2 -- "All modifications to this model: by whom, when, and which fields?"
  #
  # Needs no join to a business table and no lookup table for names: actor_label
  # is denormalized onto every audit_changes row, so the grid stays correct after
  # the user is renamed or deleted, and matches the label on the corresponding
  # audit_events row exactly (both come from one Current.actor_label string
  # computed once per entry point).
  class RecordHistory
    DEFAULT_LIMIT = 200

    attr_reader :record_type, :record_id, :range, :columns

    def initialize(record_type:, record_id: nil, range: nil, columns: nil)
      @record_type = record_type
      @record_id   = record_id
      @range       = range
      @columns     = Array(columns).reject(&:blank?)
    end

    # Screen A -- one record's full history. The single screen where an unbounded
    # range is acceptable, because one record has bounded history. It still
    # touches every partition, so it is capped with a "load older" control.
    # Index: (record_type, record_id, occurred_at DESC)
    #
    # Screen B -- every record of a class in a window. Index:
    # (record_type, occurred_at DESC), which exists specifically for this;
    # without it the record_id index degrades to scanning every row of the type.
    def changes(limit: DEFAULT_LIMIT)
      scope = AuditLog::Change.for_type(record_type)
      scope = scope.where(record_id: record_id) if record_id.present?
      scope = scope.occurred_between(range) if range
      scope = scope.touching_columns(columns) if columns.any?
      scope.newest_first.limit(limit)
    end

    # The distinct columns ever touched for this record type, to populate the
    # field filter. Bounded by the range for the same pruning reason.
    def touched_columns(limit: 500)
      scope = AuditLog::Change.for_type(record_type)
      scope = scope.occurred_between(range) if range
      scope.limit(limit).pluck(:changed_columns).flatten.uniq.sort
    end
  end
end
