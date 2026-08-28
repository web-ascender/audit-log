# frozen_string_literal: true

module AuditLog
  class Timeline
    # Another record written by the same unit of work: the "and this also
    # changed" beside an entry. One of these per (type, id), not per change row,
    # because a save that touches one record twice is still one record.
    #
    # THE ID IS NEVER DROPPED. `to_s` renders `Grommet 10mm (Product #51)` and
    # never `Grommet 10mm`, for the reason DESIGN §11.8 gives: the label is
    # resolved LIVE from the record's current row, while the id is what the log
    # actually recorded. Showing only the label lets a rename rewrite what the
    # timeline says happened. A host app building a pretty view will want to drop
    # the id -- so the pretty method is the one that keeps it.
    class TouchedRecord
      attr_reader :type, :id, :operations, :columns, :label

      def initialize(type:, id:, operations:, columns:, label: nil, label_failed: false)
        @type         = type
        @id           = id
        @operations   = operations
        @columns      = columns
        @label        = label
        @label_failed = label_failed
      end

      # The lookup raised. Deliberately NOT the same as having no label: one says
      # the host does not label this type, the other says its labeller broke.
      # Collapsing them hides a failure behind an opt-out.
      def label_failed? = @label_failed

      # A record this unit of work DELETED is not "(not found)" -- it is gone by
      # definition, which is why the identity cell never surfaces MISSING the way
      # a dangling foreign key in a diff does.
      def deleted? = operations.include?(AuditLog::Change::DELETE)
      def created? = operations.include?(AuditLog::Change::INSERT)

      # "Product #51" -- what the log recorded, always available.
      def identifier = "#{type} ##{id}"

      def to_s
        label ? "#{label} (#{identifier})" : identifier
      end

      # nil unless the host app configured config.record_url. Deliberately not
      # guessed from the class name: this library does not know the host's
      # routes, and a wrong link on an audit screen is worse than no link.
      def url = AuditLog.config.record_url&.call(type, id)

      def as_json(*)
        { "type" => type, "id" => id, "identifier" => identifier,
          "label" => label, "label_failed" => label_failed?,
          "operations" => operations, "columns" => columns,
          "display" => to_s, "url" => url }.compact
      end
    end
  end
end
