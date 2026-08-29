# frozen_string_literal: true

module AuditLog
  class Timeline
    # The IDENTITY of one Activity: which unit of work it was, and when. An
    # OPAQUE HANDLE -- a caller paginates these and hands the page straight back
    # to Timeline#activities, which loads the events, the change rows and the
    # labels for the whole page at once:
    #
    #   pagy       = pagy_keyset(timeline.activity_keys)
    #   activities = timeline.activities(pagy.records)
    #
    # It is not a value object and has no as_json on purpose: there is nothing
    # here to render. Activity is the content.
    #
    # WHY THIS IS A SEPARATE TYPE AT ALL, since one would be simpler. Three
    # constraints, and no link in the chain is optional:
    #
    #   1. Pagy needs an ActiveRecord RELATION to apply the keyset predicate and
    #      mint a cursor, and a relation yields ActiveRecord objects -- so what
    #      comes out of pagination cannot be a plain value object.
    #   2. Hydration must be BATCHED: three queries for a page. If each item
    #      loaded itself it would be three per activity.
    #   3. DESIGN §11.0 Rule 2 keeps the limit above the controller, so the
    #      library cannot paginate and hydrate in one call.
    #
    # Making Activity itself the ActiveRecord model and populating it in place
    # would collapse the two, and drags .where/.find/save into a published
    # contract -- and an unhydrated Activity answering `headline` with nil is the
    # quiet under-report this whole library exists to prevent.
    #
    # THREE THINGS HERE ARE LOAD-BEARING AND NONE OF THEM IS OBVIOUS.
    #
    # 1. `table_name` is a REAL table so ActiveRecord can introspect real column
    #    types, and Timeline aliases its subquery to that same name. The column
    #    that must be typed is `occurred_at`: Pagy serialises the keyset cursor
    #    from it, and a timestamptz that arrives as a String cannot be rendered
    #    at microsecond precision -- which is the bug Pagination::FULL_PRECISION
    #    exists to prevent. Without a real table ActiveRecord raises
    #    PG::UndefinedTable while merely LOADING this class.
    #
    # 2. `attribute :key, :string` declares the synthetic column, which no table
    #    has. Pagy needs it typed to put it in a cursor.
    #
    # 3. Callers must order with `arel_table[:key]`, never `order(key: :desc)`.
    #    A name that is not a real column renders as an Arel::Nodes::SqlLiteral,
    #    and Pagy::Keyset#extract_keyset calls `.name` on every order value:
    #    `undefined method 'name' for an instance of Arel::Nodes::SqlLiteral`.
    #
    # All three are pinned by timeline_spec's paging example, so a Rails or Pagy
    # upgrade that breaks one fails a spec rather than a screen.
    class ActivityKey < ActiveRecord::Base
      # A unit of work is normally a request_id. An out-of-band write has none --
      # request_id IS NULL, DESIGN §9 -- and each one is its own unit of work, so
      # it gets a synthetic key rather than every uncorrelated write in the log
      # collapsing into a single NULL group.
      #
      # The key is ONE non-null text column on purpose. Keying on
      # (request_id, id), with a NULL in one of the two on every row, makes the
      # row-wise keyset predicate `(a, b) < (?, ?)` evaluate to NULL -- and so
      # match nothing -- from page two onward: the timeline goes blank after the
      # first page and nothing raises. Same NULL trap that makes
      # `where.not(subject_type:, subject_id:)` wrong in RecordTimeline.
      OUT_OF_BAND_PREFIX = "row:"

      self.table_name  = "audit_changes"
      self.primary_key = "key"
      attribute :key, :string

      # An uncorrelated write: a console session, a migration, a psql
      # connection. DESIGN §9.
      def out_of_band? = key.to_s.start_with?(OUT_OF_BAND_PREFIX)

      # Duck-types a Change/Event row for Record.grouped_by_request, which needs
      # only request_id and occurred_at.
      def request_id = out_of_band? ? nil : key

      # The audit_changes.id this activity stands for, when it is a lone
      # out-of-band write. nil otherwise.
      def change_id = out_of_band? ? key.delete_prefix(OUT_OF_BAND_PREFIX).to_i : nil

      def readonly? = true
    end
  end
end
