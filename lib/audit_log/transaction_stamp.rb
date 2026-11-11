# frozen_string_literal: true

module AuditLog
  # Prepended onto the PostgreSQL adapter so that every statement this connection
  # issues carries the current actor and correlation id into the trigger.
  #
  # WHY raw_execute AND NOT begin_db_transaction
  # --------------------------------------------
  # The obvious hook is transaction start: every Active Record save and destroy
  # is wrapped in a transaction, and `set_config(..., true)` is transaction-local,
  # which gives free isolation between requests sharing a pooled connection.
  #
  # It is also incomplete, and incomplete in exactly the place this design claims
  # to be strong. `update_all`, `delete_all`, `insert_all` and `execute` issue a
  # bare statement with NO surrounding transaction, so begin_db_transaction never
  # fires and the trigger sees no settings. Those writes still get audited -- the
  # trigger cannot be bypassed -- but they land with a NULL actor and a NULL
  # request_id, indistinguishable from a console session. A design whose headline
  # claim is "update_all cannot escape the audit log" cannot then fail to say WHO
  # ran the update_all.
  #
  # raw_execute is the single choke point every Active Record statement funnels
  # through (execute, internal_exec_query, exec_insert, exec_update, exec_delete),
  # so stamping there covers the transactional and non-transactional paths alike.
  #
  # Every ACTIVE RECORD statement, and no further -- which is why raw_connection
  # is stamped too (below). DESIGN §26.
  #
  # The cost is one Ruby-level comparison per statement. The round trip itself
  # happens only when this connection's stamp does not match the current unit of
  # work -- in practice once per request, which is FEWER round trips than the
  # per-transaction approach, not more.
  module TransactionStamp
    def raw_execute(...)
      AuditLog::Context.ensure_stamped!(self)
      super
    end

    # THE OTHER WAY IN. raw_connection is Active Record's PUBLIC handoff of the
    # PG::Connection itself, and whatever is issued on it never reaches
    # raw_execute. The stamp is session-level, so such a write does not land
    # uncorrelated: it carries whatever this pooled connection last held -- an
    # EARLIER unit of work's actor. The wrong person, silently.
    #
    # sequel-activerecord_connection, which rodauth-rails runs every Rodauth query
    # through, calls this once per Sequel `synchronize` -- once per statement --
    # inside its own lease and lock, on the very adapter it is about to use. So
    # stamping HERE covers Sequel without this library naming Sequel at all, and
    # covers every other raw-connection writer besides (COPY, a host's own
    # `exec`). Active Record never calls raw_connection itself (8.0 or 8.1), so
    # this costs Active Record's own statements nothing.
    #
    # AFTER super, not before, and that order is the point: super can verify the
    # connection and REPLACE a dead session with a fresh one carrying no stamp.
    # Stamped first, a matching memo skips the write and the new, unstamped
    # session is what gets handed over. Stamped after, the stamp lands on exactly
    # the session the caller receives (raw_connection has marked the adapter
    # dirty by then, so the stamp's own query will not reconnect it again).
    #
    # The stamp is taken at HANDOUT. A caller that keeps the PG::Connection and
    # reuses it across units of work is stamped once; one that asks again per
    # unit of work, as the extension does per statement, is stamped every time.
    def raw_connection
      super.tap { AuditLog::Context.ensure_stamped!(self) }
    end

    # A reconnect silently discards session settings, so the memo has to go too
    # or the next statement will trust a value the server no longer has.
    #
    # The guard flag matters as much as the reset: configure_connection issues
    # statements of its own, and stamping during it would try to run a query
    # against a connection whose type map is not built yet.
    def configure_connection(...)
      without_audit_stamp { super }
    ensure
      AuditLog::Context.forget_stamp!(self)
    end

    # No session, nothing for the memo to describe. A REUSED adapter reconnects
    # lazily inside its next statement's with_raw_connection -- after that
    # statement's stamp check has already trusted the memo -- so it must go when
    # the session does, not when the next one arrives.
    def disconnect!(...)
      super
    ensure
      AuditLog::Context.forget_stamp!(self)
    end

    # A session-level SET issued inside a transaction is REVERTED when that
    # transaction is rolled back, and the same is true of one issued after a
    # savepoint when that savepoint is rolled back. Either way the server quietly
    # reverts to an older stamp while the connection still believes the newer one
    # is in force -- and the failure is silent and in the wrong direction: writes
    # get attributed to whoever acted before the rollback. Forgetting the memo
    # costs one round trip on the next statement and removes the whole class of
    # problem.
    #
    # THREE statements roll back, not two. ROLLBACK AND CHAIN is what Active
    # Record issues to restart a parent transaction it nested a requires_new inside
    # before the parent had written anything -- create_or_find_by's shape -- and
    # missing it credited the next write to the previous request.
    #
    # None of them is ever stamped. A rollback writes nothing, and the one time a
    # stamp in front of it is stale -- AuditLog::Current unwound by an exception
    # (a Current.set block, JobContext's around_perform) -- is the time the
    # transaction is most likely ABORTED. Context's accepts_stamp? already refuses
    # that session; this saves the round trip in the clean case too. DESIGN §26.
    def exec_rollback_db_transaction(...)
      audit_reverting { super }
    end

    def exec_rollback_to_savepoint(...)
      audit_reverting { super }
    end

    def exec_restart_db_transaction(...)
      audit_reverting { super }
    end

    # The COMMIT of an ABORTED transaction is a ROLLBACK: PostgreSQL answers it
    # with ROLLBACK and raises nothing, so Active Record believes it committed
    # while every stamp written inside was reverted. Whether it was aborted can
    # only be asked BEFORE the COMMIT is sent. A COMMIT that raises committed
    # nothing either. Forgetting is always safe; it costs one round trip.
    def commit_db_transaction(...)
      reverted = AuditLog::Context.aborted?(self)
      super
    rescue Exception
      reverted = true
      raise
    ensure
      AuditLog::Context.forget_stamp!(self) if reverted
    end

    private

    def audit_reverting(&block)
      without_audit_stamp(&block)
    ensure
      AuditLog::Context.forget_stamp!(self)
    end

    # The one way this adapter suppresses stamping. Restores rather than clears,
    # so a reconnect that runs configure_connection INSIDE a suppressed rollback
    # does not end that rollback's suppression early.
    def without_audit_stamp
      was = @audit_stamping
      @audit_stamping = true
      yield
    ensure
      @audit_stamping = was
    end
  end
end
