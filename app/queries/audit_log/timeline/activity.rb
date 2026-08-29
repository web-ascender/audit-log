# frozen_string_literal: true

module AuditLog
  class Timeline
    # ONE THING THAT HAPPENED to this record, loaded and ready to render.
    #
    # The grain is the request_id, not the audit row. A form submit that saves an
    # order and forty line items is ONE entry -- "Jane submitted this order",
    # with the order's own field changes on it and the forty line items beside it
    # -- rather than forty rows the reader has to reassemble. That is the entire
    # reason a correlation id exists (DESIGN §3).
    #
    # TWO KINDS, AND THE DIFFERENCE IS A DIFFERENCE IN GUARANTEE:
    #
    #   :narrative    a registered action emitted a summary, rendered ONCE at
    #                 emit time and stored. Immutable history -- editing the
    #                 Registry lambda changes what future rows say and never what
    #                 past rows said.
    #   :change_only  no registered action. `headline` is nil, and the host
    #                 composes its own sentence from `operations`, `record_type`
    #                 and `changed_columns`.
    #
    # `headline` returning nil rather than a generated sentence is deliberate and
    # is the same discipline as AuditLog::RecordLabel's chain ending in nil: the
    # library does not invent a phrasing, because a phrasing generated from
    # column names is this gem's wording rather than the app author's, would
    # re-render differently after a gem upgrade, and would be indistinguishable
    # on the page from a summary that was frozen at emit time. The host has i18n
    # and knows what its models are called; it gets the raw materials.
    class Activity
      attr_reader :request_id, :occurred_at, :record_type, :record_id, :events, :changes

      def initialize(record_type:, record_id:, request_id:, occurred_at:, events:, changes:, labels: nil)
        @record_type = record_type
        @record_id   = record_id
        @request_id  = request_id
        @occurred_at = occurred_at
        @events      = events
        @changes     = changes
        @labels      = labels
      end

      def kind = events.any? ? :narrative : :change_only
      def narrative?   = kind == :narrative
      def change_only? = kind == :change_only

      # An uncorrelated write: a console session, a migration, a psql connection.
      # The highest-scrutiny rows in the log, so they are never silently folded
      # in with the rest -- they get their own predicate and correlate to nothing
      # by definition. DESIGN §9.
      def out_of_band? = request_id.nil?

      # The sentence a registered action stored, or nil. Prefers the event that
      # named THIS record as its subject: one unit of work can emit several
      # actions about several records, and the one about this record is the one
      # that belongs at the top of this record's entry.
      def headline = primary_event&.summary

      def action = primary_event&.action

      # Where the write came from: web | api | job | console | system.
      #
      # nil for a change-only entry, and deliberately not guessed. `source` lives
      # on audit_events; audit_changes does not carry it, so an entry with no
      # registered action genuinely does not know -- and "console" would be a
      # plausible-looking invention for what is usually a web request whose
      # action nobody registered yet.
      def source = primary_event&.source

      def actor
        row = primary_event || changes.first
        Actor.new(type: row&.actor_type, id: row&.actor_id, label: row&.actor_label)
      end

      # The action's own payload -- the structured evidence behind the sentence.
      def metadata = primary_event&.metadata || {}

      # An erasure emptied this entry's values. NOT the same as an entry that
      # never carried any: redaction deliberately leaves no flag column, so the
      # marker string is the only trace, and an entry that cannot tell them apart
      # renders an erasure as an absence. AuditLog::Redaction.marker? is the ONE
      # definition -- do not re-spell that regex in a view. DESIGN §13.
      def redacted?
        return true if events.any? { |e| AuditLog::Redaction.marker?(e.summary) }

        changes.any? { |c| c.diff.values.any? { |v| Array(v).any? { |x| AuditLog::Redaction.marker?(x) } } }
      end

      # This record's OWN changes in this unit of work.
      def operations = changes.map(&:operation).uniq
      def created?   = operations.include?(AuditLog::Change::INSERT)
      def deleted?   = operations.include?(AuditLog::Change::DELETE)

      def changed_columns = changes.flat_map(&:changed_columns).uniq.sort

      # [FieldChange] for this record, newest write last so a column written
      # twice in one unit of work reads in the order it happened.
      def field_changes
        @field_changes ||= changes.flat_map { |change|
          change.field_changes.map do |column, from, to|
            FieldChange.new(column: column, from: from, to: to).tap do |fc|
              next unless @labels

              fc.from_label = association_label(change, column, from, :old)
              fc.to_label   = association_label(change, column, to, :new)
            end
          end
        }
      end

      # [TouchedRecord] -- the OTHER records this unit of work wrote, one per
      # (type, id). Empty for an entry that touched only this record.
      attr_writer :also_touched
      def also_touched = @also_touched ||= []

      def as_json(*)
        { "request_id" => request_id, "occurred_at" => occurred_at&.iso8601(6),
          "kind" => kind, "out_of_band" => out_of_band?, "redacted" => redacted?,
          "action" => action, "headline" => headline, "source" => source,
          "record_type" => record_type, "record_id" => record_id,
          "operations" => operations, "changed_columns" => changed_columns,
          "actor" => actor.as_json, "metadata" => metadata,
          "field_changes" => field_changes.map(&:as_json),
          "also_touched" => also_touched.map(&:as_json) }
      end

      private

      # The event about THIS record wins; otherwise the first event of the unit
      # of work, so a change correlated to an action about something else still
      # reads as that action rather than as nothing.
      def primary_event
        @primary_event ||= events.find { |e|
          e.subject_type == record_type && e.subject_id.to_s == record_id.to_s
        } || events.first
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
      def association_label(change, column, value, side)
        label = @labels.for_value(change, column, value, side: side)
        return nil if label.nil?
        return nil if label == AuditLog::LabelResolver::MISSING
        return nil if label == AuditLog::LabelResolver::FAILED

        label
      end
    end
  end
end
