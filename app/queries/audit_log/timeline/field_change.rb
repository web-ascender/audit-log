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
      # THE ONE PLACE a [FieldChange] is built out of change rows, because there
      # are now two callers and the label resolution below is the half that is
      # easy to get subtly wrong. `Activity#field_changes` builds this record's
      # own changes; `TouchedRecord#field_changes` builds another record's from
      # the same unit of work. A second hand-rolled copy is how one of them comes
      # to resolve an old id against a new polymorphic type.
      #
      # Rows arrive oldest first, so a column written twice in one unit of work
      # reads in the order it happened.
      def self.from_changes(changes, labels: nil)
        Array(changes).flat_map { |change|
          change.field_changes.map do |column, from, to|
            new(column: column, from: from, to: to).tap do |field_change|
              next unless labels

              field_change.from_label = label_for(labels, change, column, from, :old)
              field_change.to_label   = label_for(labels, change, column, to, :new)
            end
          end
        }
      end

      # Through LabelResolver#for_value, never a hand-rolled lookup: `side`
      # matters on a polymorphic column, where the type to resolve against is
      # whichever value the sibling _type column held on the SAME side of the
      # change. Resolving an old id against a new type captions the cell with the
      # wrong record entirely.
      #
      # MISSING and FAILED both collapse to nil here, and the two are NOT the
      # same thing -- one says the row was deleted, the other says the labeller
      # broke. A host app that wants to distinguish them has the id and can ask
      # the resolver directly; the timeline's contract is "a label, or none",
      # because a FieldChange carrying a sentinel would be a value object leaking
      # a lookup's internals into every host view. DESIGN §11.8.
      def self.label_for(labels, change, column, value, side)
        label = labels.for_value(change, column, value, side: side)
        return nil if label.nil?
        return nil if label == AuditLog::LabelResolver::MISSING
        return nil if label == AuditLog::LabelResolver::FAILED

        label
      end
      private_class_method :label_for

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
