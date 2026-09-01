# frozen_string_literal: true

module AuditLog
  # Both audit models are APPEND-ONLY from the application's point of view.
  #
  # `readonly?` is keyed on `persisted?` rather than hardcoded to true, because
  # ActiveRecord::Persistence#create_or_update raises ReadOnlyRecord for inserts
  # too -- a flat `def readonly? = true` would break EventSubscriber's create!.
  # Keying on persisted? gives exactly the rule wanted: rows may be inserted,
  # never updated or destroyed. It catches the realistic failure -- a developer
  # wiring a form or a data fix against the wrong model -- at no operational cost.
  #
  # Database-level enforcement (REVOKE UPDATE, DELETE + a rejecting trigger) is
  # deliberately not enabled here; it is an additive upgrade needing no schema
  # change. See plan §12.
  class Record < ActiveRecord::Base
    self.abstract_class = true

    # The real primary key is the composite (id, occurred_at) that Postgres
    # requires on a partitioned table. Declaring :id keeps ActiveRecord's finders
    # and `id` reader behaving normally; nothing writes through these models, so
    # the composite key never has to surface.
    def self.inherited(subclass)
      super
      subclass.primary_key = :id
    end

    def readonly?
      persisted?
    end

    # HOST-DEFINED FACETS, one implementation for both tables. It lives on the
    # shared base for the same reason grouped_by_request does: both tables carry a
    # `dimensions` column, the two halves of the feature are written by different
    # mechanisms (the trigger from the row, EventSubscriber from the app), and a
    # faceted query has to ask both the same question. DESIGN §23.
    #
    # THE ONE NORMALISATION POINT ON THE READ SIDE, and that is the whole reason
    # this is a method rather than a documented `where("dimensions @> ?")`. Values
    # are stored as jsonb TEXT -- `{"customer_id": "5"}` -- because
    # `{"customer_id": 5}` and `{"customer_id": "5"}` do not match under `@>` and
    # the symptom is an empty screen rather than an error. A caller passing an
    # Integer id, which is the natural thing to have in hand, gets the right query
    # here and would have got silence writing the SQL by hand.
    #
    # `@>` IS STRICT, so it implies `dimensions IS NOT NULL` and the planner
    # chooses the partial GIN index without the predicate being restated. Verified
    # rather than assumed. Multi-key containment is jsonb_path_ops's best case:
    # posting lists are intersected inside the index before the heap is touched,
    # so more facets makes this narrower rather than slower, and no combination
    # needs an index of its own.
    #
    # nil VALUES ARE DROPPED rather than matched. Absence in this column is
    # already overloaded -- a key is missing either because the value was NULL or
    # because the row predates the declaration -- so a "records with no
    # department" query cannot be answered honestly here at all. That is a
    # current-state question about business data; ask the business table.
    #
    # An empty set is a no-op returning `all`, so a screen with no filters applied
    # composes with this without special-casing it.
    def self.where_dimensions(dimensions)
      facets = normalize_dimensions(dimensions)
      return all if facets.empty?

      where("dimensions @> ?::jsonb", facets.to_json)
    end

    # Public because the auditor UI and a host app both need to render the facets
    # they are about to query by, and re-spelling this is how a screen comes to
    # display "5" while querying "5 ".
    def self.normalize_dimensions(dimensions)
      (dimensions || {}).each_with_object({}) do |(key, value), out|
        next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        out[key.to_s] = value.to_s
      end
    end

    # The rows of THIS table produced by a page of audit rows from EITHER table,
    # grouped by request_id, in one query rather than N. Both tables carry
    # request_id and occurred_at, so this lives on the shared base: a page of
    # events hydrates its change rows, and a page of change rows hydrates its
    # events, through one implementation.
    #
    # It is what turns a 40-record nested-attributes save into ONE expandable
    # entry instead of 40 rows an auditor has to reassemble.
    #
    # THE DATE BOUND IS NOT OPTIONAL, for the reason AuditLog::RequestDrillDown
    # exists to explain: `WHERE request_id IN (...)` mentions occurred_at not at
    # all, so partition elimination is syntactically impossible and the query
    # touches every partition -- six today, 84 at a 7-year horizon, on every page
    # render of every screen that drills down. The rows being expanded carry
    # their own occurred_at, so the bound costs nothing and infers nothing.
    #
    # The window is the page's own span widened by drill_down_slack on each side,
    # which is strictly more generous than the +/-slack RequestDrillDown applies
    # to a single event. A row escapes it only by sharing a request_id with a row
    # on this page while occurring more than a day from every row on it -- and a
    # request_id's lifetime is one request or one job execution, because jobs
    # deliberately do not inherit their enqueuer's id (plan 6.4).
    #
    # `rows` needs only to respond to request_id and occurred_at, which is why a
    # page of Changes and a page of Events both work.
    def self.grouped_by_request(rows, slack: nil)
      rows = Array(rows)
      return {} if rows.empty?

      scope = where(request_id: rows.filter_map(&:request_id).uniq)
      times = rows.filter_map(&:occurred_at)
      if times.any?
        slack ||= AuditLog.config.drill_down_slack
        scope = scope.where(occurred_at: (times.min - slack)..(times.max + slack))
      end

      scope.order(:occurred_at, :id).group_by(&:request_id)
    end
  end
end
