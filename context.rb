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

    class << self
      # Called before every statement. Returns immediately unless the connection's
      # stamp is stale, so the common case is two comparisons and no I/O.
      def ensure_stamped!(conn)
        return if conn.instance_variable_get(:@audit_stamping)
        return unless stamped_database?(conn)

        wanted = current_stamp
        return if conn.instance_variable_get(:@audit_stamp) == wanted

        write_stamp!(conn, wanted)
      end

      def forget_stamp!(conn)
        conn.instance_variable_set(:@audit_stamp, nil)
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
        conn.exec_query(STAMP_SQL, "AUDIT CONTEXT", wanted, prepare: true)

        # Always record what was written. The one way the server can diverge from
        # this memo is a rollback reverting a session-level SET, and
        # AuditLog::TransactionStamp clears the memo on exactly those paths.
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
      # Solid Queue's database here would put a comparison -- and periodically a
      # round trip -- on every poll and claim.
      def stamped_database?(conn)
        AuditLog.config.stamped_databases.include?(conn.pool&.db_config&.name)
      end
    end
  end
end
