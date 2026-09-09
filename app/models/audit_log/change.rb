# frozen_string_literal: true

module AuditLog
  # Layer 1: one row per row-level change, written by the database trigger.
  #
  # This table is COMPLETE in a way audit_events is not: audit_events only holds
  # actions someone remembered to register, whereas every INSERT, UPDATE and
  # DELETE on an audited table lands here regardless of how it was issued.
  class Change < Record
    self.table_name = "audit_changes"

    INSERT = "I"
    UPDATE = "U"
    DELETE = "D"

    OPERATION_NAMES = { INSERT => "Created", UPDATE => "Updated", DELETE => "Deleted" }.freeze

    scope :occurred_between, ->(range) { where(occurred_at: range) }
    scope :by_actor, ->(type, id) { where(actor_type: type, actor_id: id) }
    scope :for_record, ->(type, id) { where(record_type: type, record_id: id) }
    scope :for_type, ->(type) { where(record_type: type) }
    scope :newest_first, -> { order(occurred_at: :desc, id: :desc) }
    scope :modifications, -> { where(operation: [UPDATE, DELETE]) }

    # Uncorrelated writes: a console session, a migration, a manual psql
    # connection. The highest-scrutiny rows in the log, so they get a named scope
    # and their own screen rather than being hidden.
    scope :out_of_band, -> { where(request_id: nil) }

    # Served by the GIN index on changed_columns.
    #
    # The intuitive query is `diff ? 'status'` and it has two independent traps.
    # First, `?` is a bind placeholder in ActiveRecord, so the jsonb operator has
    # to be written `??` or as jsonb_exists(). Second, and silently: a GIN index
    # built with jsonb_path_ops does not support `?` AT ALL, so the planner drops
    # to a sequential scan and nothing warns you.
    scope :touching_columns, ->(*cols) {
      where("changed_columns && ARRAY[?]::text[]", cols.flatten.map(&:to_s))
    }

    # A class method because the callers hold a bare operation code rather than a
    # row: the auditor UI's badge helper and a host app's own. One definition, so
    # a screen cannot invent a fourth spelling for a delete.
    def self.operation_name(operation)
      OPERATION_NAMES.fetch(operation, operation)
    end

    def created?  = operation == INSERT
    def updated?  = operation == UPDATE
    def deleted?  = operation == DELETE

    def out_of_band? = request_id.nil?

    def actor_display
      AuditLog::ActorLabel.display(actor_type, actor_id, actor_label)
    end

    # [[column, old, new], ...] sorted for stable rendering.
    def field_changes
      diff.map { |col, (old_value, new_value)| [col, old_value, new_value] }
          .sort_by { |col, _, _| col }
    end

    def label = AuditLog::Identity.for(record_type, record_id)
  end
end
