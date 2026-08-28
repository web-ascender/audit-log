# frozen_string_literal: true

module AuditLog
  class Timeline
    # One column's before and after, with the three nil shapes named.
    #
    # THIS OBJECT EXISTS SO A HOST APP CANNOT GET THOSE SHAPES WRONG. A raw diff
    # value is `[old, new]`, and the auditor UI encodes rules about it that are
    # invisible from the outside (DESIGN §11.2):
    #
    #   ["pending", "approved"]  changed        Pending -> Approved
    #   [nil, "approved"]        set on insert  (not set) -> Approved
    #   ["approved", nil]        CLEARED        Approved -> (cleared)
    #
    # A screen that renders the second and third identically reports a field
    # being emptied as a field being filled in. Shipping the relation alone
    # leaves every host app to re-derive that; shipping this makes it a method
    # call.
    class FieldChange
      attr_reader :column, :from, :to

      def initialize(column:, from:, to:)
        @column = column
        @from   = from
        @to     = to
      end

      # The value was there and is now gone. Distinct from never having been set,
      # and the distinction is the whole point of this class.
      def cleared? = !from.nil? && to.nil?

      # No prior value: an insert, or a column that was NULL.
      def set? = from.nil? && !to.nil?

      # An id pointing at another record, when the host has opted that type into
      # labelling. Resolved LIVE, and the id is never dropped -- DESIGN §11.8.
      # `Grommet 10mm (id: 51)`, never `Grommet 10mm`: the label annotates the
      # recorded fact, it does not replace it, and a timeline that shows only the
      # label has become a report of current state.
      attr_accessor :from_label, :to_label

      def association? = !(from_label.nil? && to_label.nil?)

      def as_json(*)
        { "column" => column, "from" => from, "to" => to,
          "cleared" => cleared?, "set" => set?,
          "from_label" => from_label, "to_label" => to_label }.compact
      end
    end
  end
end
