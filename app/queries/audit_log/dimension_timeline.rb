# frozen_string_literal: true

module AuditLog
  # "Everything that happened to invoices in department 5" -- the fourth kind of
  # question, and the one this library cannot pose on its own, because the facet
  # belongs to the host application. DESIGN §23.
  #
  # It is AuditLog::Timeline WITH THE RECORD PREDICATE SWAPPED FOR A CONTAINMENT
  # TEST, and subclassing rather than copying is the design. The union over both
  # tables, the unit-of-work key, the batched hydration, the keyset relation and
  # every value object are inherited: a second hand-written copy of that query is
  # how one of the two comes to lose the events leg, or the COALESCE that stops
  # every uncorrelated write collapsing into one NULL group. Both mistakes have
  # already been made once each in this library's history.
  #
  # BOTH LEGS FILTER THEIR OWN COLUMN, and that is why `dimensions` is on both
  # tables rather than only on `audit_changes`. With the column on the changes
  # table alone the events leg would need
  # `request_id IN (SELECT ... FROM audit_changes ...)` -- a semi-join, evaluated
  # twice, on the one query in this library that is already a union over two
  # partitioned tables. A column on each deletes it. A unit qualifies if EITHER
  # table matched, and #activities then hydrates the whole of it, so nothing is
  # half-loaded.
  #
  # The two halves cover each other's holes, which is layer 1 and layer 2 one
  # level down:
  #
  #   audit_changes.dimensions   every write -- update_all, delete_all, raw SQL,
  #                              a DB cascade, a console session, a migration.
  #                              Cannot reach anything that is not a column on
  #                              the row that changed.
  #   audit_events.dimensions    anything the application knows -- an N-hop
  #                              denormalisation, the current tenant, a tag, the
  #                              deployed version. Cannot reach a write with no
  #                              registered action.
  #
  # WHAT A FILTER RETURNS LESS OF, and each of these is a screen that renders
  # perfectly while answering a narrower question than a reader assumes:
  #
  #   * NOT RETROACTIVE, in both halves. A facet declared today says nothing about
  #     yesterday, and those rows carry NULL, which `@>` can never match.
  #   * A CONJUNCTION HAS TO FIT ON ONE ROW. `@>` matches a single jsonb value, so
  #     {customer_id: 5, product_id: 12} finds nothing when customer_id lives on
  #     `orders` and product_id on `line_items`. Declaring both facets on one table
  #     is the supported answer; intersecting request_ids across facets is a
  #     different and more expensive query, and it is not built.
  #   * DEPARTURES ARE NOT CAPTURED. A row is filed under the value it held AFTER
  #     the change, so an invoice moving from department 5 to 9 shows in 5's feed
  #     up to but not including the row that took it away.
  class DimensionTimeline < Timeline
    # THE ONE PLACE IN THIS LIBRARY THAT IS BOUNDED BY DEFAULT, and the divergence
    # from Timeline's "unbounded on purpose" is deliberate rather than an
    # oversight. An unfiltered facet scan across 84 partitions where
    # `department_id = 5` matches a third of the table is genuinely slow, and the
    # resolution is the one RequestDrillDown already established: bound
    # generously, DISCLOSE THE BOUND ON THE SCREEN, and offer the escape.
    # Disclosed truncation is not invisible truncation, so the rule is satisfied
    # rather than broken -- `scope_description` is what says so, and it names the
    # facets as well as the window.
    #
    # `range: nil` PASSED EXPLICITLY IS UNBOUNDED, and that distinction is why the
    # default lives in the signature rather than behind a `||=`: `||=` cannot tell
    # "not passed" from an explicit nil, and an explicit nil is how a caller asks
    # for the whole of retained history. Same rule the retention and rollup
    # keywords follow.
    DEFAULT_WINDOW = 30.days

    def self.default_range = DEFAULT_WINDOW.ago..Time.current

    attr_reader :dimensions

    # dimensions: { department_id: 5, shipping_location_id: 12 } -- any combination
    # of the facets the host declared. Values are normalised to text by
    # AuditLog::Record.where_dimensions, so an Integer id works and a caller
    # cannot produce the silent no-match that `{"customer_id": 5}` against stored
    # text would be.
    def initialize(dimensions:, range: AuditLog::DimensionTimeline.default_range, labels: nil)
      @dimensions = AuditLog::Record.normalize_dimensions(dimensions)
      # There is no record here. Timeline reads these two only through the
      # predicates and the anchor, all three of which this class replaces.
      super(record_type: nil, record_id: nil, range: range, labels: labels)
    end

    # True when no facet survived normalisation -- every value nil or blank. The
    # query would then be the whole log, which is never what a filter screen
    # means, so the caller renders a prompt instead of a feed.
    def unfiltered? = dimensions.empty?

    # Names the FACETS as well as the window, because a faceted feed narrowed two
    # ways must not look like one narrowed in either.
    def scope_description
      facets = dimensions.map { |key, value| "#{key} = #{value}" }.join(", ")
      window = super
      return window if facets.empty?

      "#{facets} — #{window}"
    end

    private

    def containment
      AuditLog::Change.sanitize_sql_array(["dimensions @> ?::jsonb", dimensions.to_json])
    end

    # 1=0 rather than a raise: an empty filter set is a screen state, not a
    # programming error, and a relation that returns nothing is what lets the
    # controller page and render it like any other. Never `all` -- that would turn
    # a cleared filter into a scan of the entire audit log.
    def changes_predicate = unfiltered? ? "1 = 0" : containment
    def events_predicate  = unfiltered? ? "1 = 0" : containment

    def history_before?(before)
      return false if unfiltered?

      AuditLog::Change.where_dimensions(dimensions).where(occurred_at: before).exists? ||
        AuditLog::Event.where_dimensions(dimensions).where(occurred_at: before).exists?
    end

    # WHICH RECORD AN ACTIVITY IS ABOUT, when the question was about a facet and
    # not about a record. Timeline is handed one and anchors every activity on it;
    # here it has to be derived, and the order below is the whole of the decision:
    #
    #   1. THE EVENT'S SUBJECT, when the unit has a registered action that named
    #      one. That is the aggregate root the action was about, so the headline,
    #      the field changes and the "also touched" list all line up the way they
    #      do on that record's own timeline -- Activity#primary_event prefers the
    #      event whose subject matches the anchor, and this is what makes it match.
    #   2. THE FIRST CHANGE ROW THAT MATCHED THE FACET, otherwise. On a bulk update
    #      with no registered action, that is the row the reader came for.
    #   3. THE FIRST CHANGE ROW, otherwise -- the unit qualified through its event
    #      alone, and something has to carry the entry.
    #
    # The rest of the unit is never dropped: whatever is not the anchor becomes
    # `also_touched`, which is complete for the unit either way. Anchoring on
    # nothing was the alternative and it is strictly worse -- `mine` would be
    # empty, so the entry would render with no field changes at all, which reads
    # as "nothing changed" on a screen whose entire job is saying what did.
    def anchor_for(related, events)
      subject = events.find { |e| e.subject_type.present? && e.subject_id.present? }
      return [subject.subject_type, subject.subject_id.to_s] if subject

      row = related.find { |c| matched?(c) } || related.min_by { |c| [c.occurred_at, c.id] }
      row ? [row.record_type, row.record_id.to_s] : [nil, nil]
    end

    # Re-checked in Ruby against the rows already loaded, not asked of the
    # database again: #activities hydrates the WHOLE unit of work, so most of what
    # comes back legitimately did not match the facet itself.
    def matched?(change)
      dimensions.all? { |key, value| change.dimensions&.[](key) == value }
    end
  end
end
