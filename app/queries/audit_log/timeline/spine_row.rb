# frozen_string_literal: true

module AuditLog
  class Timeline
    # One UNIT OF WORK on the spine: a `uow` key and the latest instant that unit
    # touched this record. Not a row of either audit table -- a row of the union
    # over both (Timeline#spine).
    #
    # THREE THINGS HERE ARE LOAD-BEARING AND NONE OF THEM IS OBVIOUS.
    #
    # 1. `table_name` is a REAL table so ActiveRecord can introspect real column
    #    types, and Timeline#spine aliases its subquery to that same name. The
    #    only column that must be typed is `occurred_at`: Pagy serialises the
    #    keyset cursor from it, and a timestamptz that arrives as a String cannot
    #    be rendered at microsecond precision -- which is the bug
    #    Pagination::FULL_PRECISION exists to prevent. Without a real table
    #    ActiveRecord raises PG::UndefinedTable on `spine`::regclass while merely
    #    LOADING the class.
    #
    # 2. `attribute :uow, :string` declares the synthetic column, which no table
    #    has. Pagy needs it typed to put it in a cursor.
    #
    # 3. Callers must order with `arel_table[:uow]`, never `order(uow: :desc)`.
    #    A name that is not a real column renders as an Arel::Nodes::SqlLiteral,
    #    and Pagy::Keyset#extract_keyset calls `.name` on every order value:
    #    `undefined method 'name' for an instance of Arel::Nodes::SqlLiteral`.
    #
    # All three are pinned by timeline_spine_spec's paging example, so a Rails or
    # Pagy upgrade that breaks one fails a spec rather than a screen.
    class SpineRow < ActiveRecord::Base
      # A unit of work is normally a request_id. An out-of-band write has none --
      # request_id IS NULL, DESIGN §9 -- and each one is its own unit of work, so
      # it gets a synthetic key rather than collapsing every uncorrelated write in
      # the log into a single NULL group.
      #
      # The key is ONE non-null text column on purpose. Keying on
      # (request_id, id), with a NULL in one of the two on every row, makes the
      # row-wise keyset predicate `(a, b) < (?, ?)` evaluate to NULL -- and so
      # match nothing -- from page two onward. Same NULL trap that makes
      # `where.not(subject_type:, subject_id:)` wrong in RecordTimeline.
      OOB_PREFIX = "row:"

      self.table_name  = "audit_changes"
      self.primary_key = "uow"
      attribute :uow, :string

      def out_of_band? = uow.to_s.start_with?(OOB_PREFIX)

      # Duck-types a Change/Event row for Record.grouped_by_request, which needs
      # only request_id and occurred_at.
      def request_id = out_of_band? ? nil : uow

      # The audit_changes.id this unit of work stands for, when it is a lone
      # out-of-band write.
      def change_id = out_of_band? ? uow.delete_prefix(OOB_PREFIX).to_i : nil

      def readonly? = true
    end
  end
end
