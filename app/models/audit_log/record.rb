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
