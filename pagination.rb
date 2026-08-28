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
    # Deliberately not a page-size selector in the UI. A limit is a rendering
    # decision, not an auditing one, and an unbounded one is how a screen gets
    # used as an export -- which is what the CSV endpoint is for.
    def paginate(scope, limit: nil)
      limit ||= AuditLog.config.page_size
      cursor = params[:page].presence

      Pagy::Keyset.new(scope, limit: limit, page: cursor)
    rescue Pagy::InternalError, ArgumentError, TypeError, JSON::ParserError
      # A cursor minted on a different screen, or hand-edited. It is meaningless
      # outside the ordering it came from, and Pagy raises rather than guessing.
      # Falling back to the first page is the only safe answer -- silently
      # applying a mismatched cursor would drop rows off an audit screen.
      Pagy::Keyset.new(scope, limit: limit)
    end
  end
end
