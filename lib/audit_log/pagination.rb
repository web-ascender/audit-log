# frozen_string_literal: true

require "pagy"
require "pagy/keyset"

module AuditLog
  # Keyset pagination for the auditor screens. DESIGN §11.0 Rule 2.
  #
  # Offset pagination is wrong here for two separate reasons, and both get worse
  # exactly as the audit log gets valuable:
  #
  #   * `OFFSET 200000` re-reads and discards every skipped row.
  #   * `SELECT count(*)` over a partitioned table with millions of rows blocks
  #     the page to render a number nobody acts on.
  #
  # So there are no page numbers and no total: a cursor, and "older". The cursor
  # is an opaque base64 token carrying the last row's `(occurred_at, id)`, which
  # is unique because `id` comes from one sequence shared across all partitions.
  #
  # The keyset predicate is ANDed onto the screen's existing date range rather
  # than replacing it, so paging does not cost the partition pruning that Rule 1
  # bought. Verified in spec/audit_log/pagination_spec.rb.
  module Pagination
    # Serialize the cursor's timestamp at MICROSECOND precision.
    #
    # This is not a nicety. Pagy builds the cursor with `hash.to_json`, and
    # ActiveSupport renders a Time at ActiveSupport::JSON::Encoding.time_precision
    # -- which defaults to 3, milliseconds. `occurred_at` is timestamptz filled by
    # clock_timestamp(), which is microseconds, and in practice every row carries
    # sub-millisecond digits.
    #
    # A truncated cursor therefore names an instant slightly EARLIER than the row
    # it was minted from, and the next page's `occurred_at < cursor` skips every
    # row in the gap. Rows vanish between pages, silently -- the exact failure
    # keyset pagination was introduced here to eliminate. It surfaces as a flake,
    # because it needs a row to land inside that sub-millisecond window at a page
    # boundary: roughly one full-suite run in eight before this was fixed.
    #
    # Scoped to this cursor rather than raising the global time_precision, which
    # would change every JSON response the host application renders.
    FULL_PRECISION = lambda do |attributes|
      attributes.transform_values { |v| v.acts_like?(:time) ? v.iso8601(6) : v }.to_json
    end

    # Deliberately not a page-size selector in the UI. A limit is a rendering
    # decision, not an auditing one, and an unbounded one is how a screen gets
    # used as an export -- which is what the CSV endpoint is for.
    def paginate(scope, limit: nil)
      limit ||= AuditLog.config.page_size
      cursor = params[:page].presence

      Pagy::Keyset.new(scope, limit: limit, page: cursor,
                       jsonify_keyset_attributes: FULL_PRECISION)
    rescue Pagy::InternalError, ArgumentError, TypeError, JSON::ParserError
      # A cursor minted on a different screen, or hand-edited. It is meaningless
      # outside the ordering it came from, and Pagy raises rather than guessing.
      # Falling back to the first page is the only safe answer -- silently
      # applying a mismatched cursor would drop rows off an audit screen.
      Pagy::Keyset.new(scope, limit: limit, jsonify_keyset_attributes: FULL_PRECISION)
    end
  end
end
