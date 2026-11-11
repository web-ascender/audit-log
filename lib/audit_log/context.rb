# frozen_string_literal: true

module AuditLog
  module Context
    # One statement, four settings. `false` in the third argument means
    # SESSION-level rather than transaction-local: a transaction-local setting
    # would be invisible to a bare `update_all`, which never opens one.
    STAMP_SQL = <<~SQL.squish
      SELECT set_config('audit.request_id',  $1, false),
             set_config('audit.actor_type',  $2, false),
             set_config('audit.actor_id',    $3, false),
             set_config('audit.actor_label', $4, false)
    SQL

    # What the stamp is logged and instrumented as. A constant because specs count
    # stamp round trips by it, and a renamed literal there would count zero and
    # turn "spends no round trip" assertions vacuous.
    STAMP_QUERY_NAME = "AUDIT CONTEXT"

    class << self
      # Called before every statement. Returns immediately unless the connection's
      # stamp is stale, so the common case is two comparisons and no I/O.
      def ensure_stamped!(conn)
        return if conn.instance_variable_get(:@audit_stamping)
        return unless stamped_database?(conn)

        wanted = current_stamp
        return if conn.instance_variable_get(:@audit_stamp) == wanted
        return unless accepts_stamp?(conn)

        write_stamp!(conn, wanted)
      end

      def forget_stamp!(conn)
        conn.instance_variable_set(:@audit_stamp, nil)
      end

      # Whether the session is inside an aborted transaction. PostgreSQL turns the
      # COMMIT of one into a ROLLBACK without raising, so the caller -- the COMMIT
      # hook -- has to ask before the COMMIT is sent.
      def aborted?(conn)
        session_status(conn) == PG::PQTRANS_INERROR
      end

      # Mint a fresh correlation id. UUIDv7, not v4: request_id is indexed on the
      # highest-volume table in the database, and v7 is timestamp-prefixed, so
      # inserts concentrate at the right edge of the B-tree instead of scattering
      # page splits across the whole index.
      def new_request_id
        SecureRandom.uuid_v7
      end

      # The inverse of new_request_id: the instant a v7 id was minted, read out of
      # the id itself with no database access.
      #
      # This is what lets the drill-down prune partitions. `WHERE request_id = ?`
      # carries no predicate on occurred_at, so the planner cannot eliminate a
      # single partition and scans all of them -- 84 of them at a 7-year retention
      # horizon. A v7 id carries its own timestamp (RFC 9562: the first 48 bits are
      # milliseconds since the Unix epoch), so the value already being filtered on
      # supplies the bound. See AuditLog::RequestDrillDown.
      #
      # Returns nil unless the id really is a v7 UUID. This matters: in a v4 id
      # those 48 bits are random, so decoding one yields a plausible-looking
      # timestamp somewhere in the next half-million years, and a drill-down bounded
      # by it would silently return nothing. Nil means "no bound available", and the
      # caller degrades to an unbounded scan rather than to a wrong answer.
      def minted_at(request_id)
        hex = request_id.to_s.delete("-")
        return nil unless hex.match?(/\A\h{32}\z/)
        return nil unless hex[12] == "7"   # version nibble; bits 48..51

        Time.at(hex[0, 12].to_i(16) / 1000.0).utc
      end

      private

      # ONE rule for every path that stamps -- an Active Record statement, a COMMIT,
      # a ROLLBACK AND CHAIN, a raw_connection handoff -- instead of a guard per
      # hook, because the per-hook version already missed one. A session inside an
      # ABORTED transaction (INERROR) accepts nothing but a rollback, and one partway
      # through a command (ACTIVE: a COPY streaming) accepts nothing at all; sending
      # the stamp into either fails, and takes the caller's own statement -- or the
      # rollback that would have recovered the transaction -- down with it. Skipped,
      # nothing is written, so the memo still matches the server.
      #
      # Asked only once the memo has already said a stamp is needed, so the common
      # case pays nothing. libpq answers from local state: no round trip.
      def accepts_stamp?(conn)
        status = session_status(conn)
        status != PG::PQTRANS_INERROR && status != PG::PQTRANS_ACTIVE
      end

      # nil when there is no session yet -- the stamp's own query will connect one,
      # so that must not read as a refusal -- or when libpq cannot say.
      def session_status(conn)
        conn.instance_variable_get(:@raw_connection)&.transaction_status
      rescue PG::Error
        nil
      end

      def current_stamp
        [
          AuditLog::Current.request_id.to_s,
          AuditLog::Current.actor_type.to_s,
          AuditLog::Current.actor_id.to_s,
          AuditLog::Current.actor_label.to_s
        ]
      end

      def write_stamp!(conn, wanted)
        conn.instance_variable_set(:@audit_stamping, true)
        conn.exec_query(STAMP_SQL, STAMP_QUERY_NAME, wanted, prepare: true)

        # Always record what was written. The server diverges from this memo only
        # when something reverts or discards a session-level SET -- a ROLLBACK, a
        # ROLLBACK TO SAVEPOINT, a ROLLBACK AND CHAIN, the COMMIT of an aborted
        # transaction (which PostgreSQL turns into a ROLLBACK), a reconnect, a
        # disconnect -- and AuditLog::TransactionStamp clears the memo on each.
        #
        # An earlier version instead skipped memoizing while a transaction was
        # open. That was worse, not safer: the memo then went stale in the
        # "unstamped" direction, so a later reset to the empty stamp matched the
        # stale memo, short-circuited, and left the PREVIOUS actor's identity in
        # force on the connection.
        conn.instance_variable_set(:@audit_stamp, wanted)
      ensure
        conn.instance_variable_set(:@audit_stamping, false)
      end

      # Only databases that actually hold audited tables pay for this. Naming
      # Solid Queue's connection in config.correlated_connections would put a
      # comparison -- and periodically a round trip -- on every poll and claim.
      #
      # Note what a `false` here does and does not do: the connection carries no
      # correlation context, so the trigger reads no request_id and no actor. It
      # still fires, and still writes every row. This gates correlation, not
      # auditing.
      def stamped_database?(conn)
        AuditLog.config.correlated_connections.include?(conn.pool&.db_config&.name)
      end
    end
  end
end
