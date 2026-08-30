# frozen_string_literal: true

require "json"

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
  #
  # WHY THIS IS HAND-ROLLED RATHER THAN `Pagy::Keyset`.
  #
  # It was Pagy's until 0.2.0, and the swap is not a preference. Keyset paging
  # exists in Pagy only from 9.0, and the one hook this module cannot work
  # without -- `jsonify_keyset_attributes:`, which is how FULL_PRECISION below
  # reaches the cursor -- only from 9.3. Pagy 43 then removed that hook again in
  # its rewrite. So a `pagy` dependency this module can trust spans 9.3 and 9.4
  # and nothing else, and a host app is allowed exactly one Pagy in its bundle:
  # an app on Pagy 5, or on current Pagy, could not install this gem at all.
  #
  # Forcing every adopter's own pagination across a major upgrade -- in both
  # directions -- to satisfy an audit gem is a bad trade for the ~90 lines below,
  # all of which is logic this module already had opinions about. Nothing used
  # Pagy's frontend: `audit_pagination` renders the engine's own nav, and a host
  # renders `url_for(page: page.next)`. What was actually imported was a keyset
  # predicate and a base64 cursor.
  module Pagination
    # Serialize the cursor's timestamp at MICROSECOND precision.
    #
    # This is not a nicety. The cursor is built with `hash.to_json`, and
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

    # Raised when a scope cannot be paginated, or a cursor does not belong to the
    # scope it was handed to. `paginate` catches it and restarts at the newest
    # row; see the rescue there for why that is the only safe recovery.
    class InvalidCursor < StandardError; end

    # Base64 without the padding or the URL-hostile bytes, so a cursor survives a
    # query string untouched. Deliberately not `Base64.urlsafe_encode64` -- the
    # cursor is round-tripped through `url_for`, and `=` padding comes back
    # percent-encoded from some proxies.
    module Cursor
      module_function

      def encode(json)
        str = [json].pack("m0")
        str.chomp!("==") || str.chomp!("=")
        str.tr("+/", "-_")
      end

      def decode(str)
        padded = str.tr("-_", "+/")
        padded = padded.ljust((padded.length + 3) & ~3, "=") unless padded.length % 4 == 0
        padded.unpack1("m0")
      end
    end

    # One page of a keyset-paginated scope: the rows, and the cursor for the page
    # after it. The public shape is `records` and `next`, which is what the
    # auditor screens, the generated host views and README all already render --
    # it is unchanged from the Pagy object this replaced.
    class Page
      attr_reader :records

      def initialize(scope, limit:, cursor: nil)
        @limit  = limit
        @keyset = extract_keyset(scope)
        raise InvalidCursor, "the scope must be ordered" if @keyset.empty?

        @latest  = typecast(scope, decode(cursor)) if cursor
        @records = fetch(scope)
      end

      # The cursor for the next page, or nil at the end of the results. The
      # screens render "End of results." off that nil, which is the honest form
      # of what a fixed row cap could only imply.
      def next
        return unless @more

        @next ||= Cursor.encode(FULL_PRECISION.call(@records.last.slice(*@keyset.keys)))
      end

      private

      # {column => :asc/:desc}, in the scope's own order.
      #
      # `node.value.name` is why a caller must order through `arel_table[:col]`
      # and never `order(key: :desc)` on a synthetic column: a name that is not a
      # real column arrives as an Arel::Nodes::SqlLiteral, which has no `name`.
      # That was Pagy's constraint and it is still ours -- the ordering has to be
      # decomposable into columns to build a predicate out of. It raises
      # InvalidCursor rather than NoMethodError, which is the one improvement.
      def extract_keyset(scope)
        scope.order_values.each_with_object({}) do |node, keyset|
          value = node.try(:value)
          unless node.respond_to?(:direction) && value.respond_to?(:name)
            raise InvalidCursor, "cannot paginate an ordering that is not a column: #{node.inspect}"
          end

          keyset[value.name.to_s] = node.direction
        end
      end

      def decode(cursor)
        JSON.parse(Cursor.decode(cursor))
      rescue ArgumentError, JSON::ParserError => e
        raise InvalidCursor, "unreadable cursor: #{e.message}"
      end

      # Through the model's own attribute types, so `occurred_at` comes back a
      # Time and not the String it was serialized as. This is why ActivityKey
      # declares `attribute :key, :string` for a column no table has.
      def typecast(scope, latest)
        unless latest.keys.sort == @keyset.keys.sort
          raise InvalidCursor, "cursor #{latest.keys.inspect} does not match ordering #{@keyset.keys.inspect}"
        end

        scope.model.new(latest).slice(*@keyset.keys)
      end

      # limit + 1 to learn whether there is a next page without a COUNT.
      def fetch(scope)
        scope   = with_keyset_columns(scope)
        scope   = scope.where(*newest_predicate(scope)) if @latest
        rows    = scope.limit(@limit + 1).to_a
        @more   = rows.size > @limit
        @more ? rows.first(@limit) : rows
      end

      # A scope with an explicit select must still carry the columns the cursor
      # is minted from, or `next` reads an attribute that was never loaded.
      def with_keyset_columns(scope)
        return scope if scope.select_values.empty?

        missing = @keyset.keys - scope.select_values.map(&:to_s)
        missing.empty? ? scope : scope.select(*missing)
      end

      # The row-wise "strictly after the cursor" comparison, spelled as an OR of
      # ANDs rather than as a tuple `(a, b) < (?, ?)`.
      #
      # The tuple form is shorter and is a trap here: it evaluates to NULL, and
      # so matches nothing, if any component is NULL -- the timeline would go
      # blank after page one and nothing would raise. ActivityKey's synthetic
      # `key` exists to keep a NULL out of this comparison; spelling it out keeps
      # the guarantee even where a caller has not.
      #
      #   ( a = :a AND b < :b ) OR ( a < :a )
      def newest_predicate(scope)
        table  = scope.model.arel_table.name
        quoted = @keyset.keys.to_h { |c| [c, "#{quote_table(scope, table)}.#{quote_column(scope, c)}"] }
        pairs  = @keyset.to_a
        clauses = []

        until pairs.empty?
          last_column, last_direction = pairs.pop
          equalities = pairs.map { |column, _| "#{quoted[column]} = :#{column}" }
          comparison = "#{quoted[last_column]} #{last_direction == :desc ? "<" : ">"} :#{last_column}"
          clauses << "( #{(equalities << comparison).join(" AND ")} )"
        end

        [clauses.join(" OR "), @latest.symbolize_keys]
      end

      def quote_table(scope, name)  = scope.model.connection.quote_table_name(name)
      def quote_column(scope, name) = scope.model.connection.quote_column_name(name)
    end

    # Deliberately not a page-size selector in the UI. A limit is a rendering
    # decision, not an auditing one, and an unbounded one is how a screen gets
    # used as an export -- which is what the CSV endpoint is for.
    def paginate(scope, limit: nil)
      limit ||= AuditLog.config.page_size

      Page.new(scope, limit: limit, cursor: params[:page].presence)
    rescue InvalidCursor
      # A cursor minted on a different screen, or hand-edited. It is meaningless
      # outside the ordering it came from. Falling back to the first page is the
      # only safe answer -- silently applying a mismatched cursor would drop rows
      # off an audit screen.
      Page.new(scope, limit: limit)
    end
  end
end
