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
  # raw_execute is the single choke point every statement funnels through
  # (execute, internal_exec_query, exec_insert, exec_update, exec_delete), so
  # stamping there covers the transactional and non-transactional paths alike.
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

    # A reconnect silently discards session settings, so the memo has to go too
    # or the next statement will trust a value the server no longer has.
    #
    # The guard flag matters as much as the reset: configure_connection issues
    # statements of its own, and stamping during it would try to run a query
    # against a connection whose type map is not built yet.
    def configure_connection(...)
      @audit_stamping = true
      super
    ensure
      @audit_stamping = false
      AuditLog::Context.forget_stamp!(self)
    end

    # A session-level SET issued inside a transaction is REVERTED by a rollback,
    # and the same is true of one issued after a savepoint when that savepoint is
    # rolled back. Either way the server quietly reverts to an older stamp while
    # the connection still believes the newer one is in force -- and the failure
    # is silent and in the wrong direction: writes get attributed to whoever
    # acted before the rollback. Forgetting the memo costs one round trip on the
    # next statement and removes the whole class of problem.
    def exec_rollback_db_transaction(...)
      super
    ensure
      AuditLog::Context.forget_stamp!(self)
    end

    def exec_rollback_to_savepoint(...)
      super
    ensure
      AuditLog::Context.forget_stamp!(self)
    end
  end
end
