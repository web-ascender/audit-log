# frozen_string_literal: true

module AuditLog
  # Every host-application coupling point lives here, so extracting this
  # directory into a gem requires no edits to the library itself.
  class Configuration
    # Columns never written to the diff, on any table. Rationale, in order:
    # timestamps are noise on every single row; lock_version is bookkeeping;
    # the credential columns must not have their values (even old ones) copied
    # into a second table. Per-table additions go in the migration.
    DEFAULT_EXCLUDED_COLUMNS = %w[
      created_at updated_at lock_version
      password_digest encrypted_password remember_created_at
      reset_password_token reset_password_sent_at
    ].freeze

    # Only databases that actually contain audited tables get the correlation
    # round trip on transaction start. Naming Solid Queue's database here would
    # add a round trip to every poll and claim -- plan §6.4.
    attr_accessor :stamped_databases

    # String, resolved lazily: the engine's controllers inherit from this, which
    # is how they pick up the host app's layout, authentication, and helpers.
    attr_accessor :parent_controller

    # ->(controller) { }  Called as a before_action in every audit screen.
    # Raise or redirect to deny. Default is a no-op, which is correct for a demo
    # and wrong for anything else.
    attr_accessor :authorize

    # ->(controller) { controller.current_user }  Resolves the acting user from a
    # controller. Configurable so the library never names an authentication gem;
    # the default works with Devise, the Rails authentication generator, and
    # anything else that exposes `current_user` in controller scope.
    attr_accessor :actor_resolver

    # ->(query) { User.where(...).limit(50) }  Populates the actor picker.
    #
    # Sourced from the actor table, never from the audit log: an auditor
    # searching for "Jane Doe" wants to find her whether or not she has activity
    # in the current window, and SELECT DISTINCT actor_id over audit_changes
    # would be unusable at volume. Deleted users are the resulting gap; if the
    # picker must include them, back it with a nightly materialized view rather
    # than a live-maintained lookup table.
    attr_accessor :actor_picker

    # ->(type, id) { type.safe_constantize&.find_by(id: id) }
    attr_accessor :actor_finder

    # ->(actor) { "Jane Doe <jane@example.com>" }  Rendered once per entry point
    # and snapshotted onto every row. See ActorLabel.
    attr_accessor :actor_label_resolver

    # Classes permitted to call AuditLog.without_logging. Empty array means the
    # bypass is unavailable, which is the right default.
    attr_accessor :bypass_allowlist

    attr_accessor :default_excluded_columns

    # Tables that legitimately have no audit trigger. The coverage spec fails the
    # build for any table in the primary database that is neither audited nor
    # listed here, so every exemption carries a written reason.
    attr_accessor :unaudited_tables

    # How far ahead the partition job keeps partitions provisioned. A missing
    # future partition is a write-path outage, so this has margin.
    attr_accessor :partition_months_ahead

    # How long audit rows are kept. A partition is eligible for retirement once
    # its UPPER bound is older than this -- never its lower, or a month still
    # holding in-horizon days would go. nil disables retirement entirely.
    #
    # Seven years is the common denominator of the horizons that actually drive
    # this decision (SOX at seven, HIPAA at six, most commercial contracts at
    # five or fewer). It is a starting point to be overridden per application,
    # not a legal opinion.
    attr_accessor :retention

    # :detach or :drop. Detaching is reversible with a single ATTACH and leaves
    # the data in the schema under a `_retired_` name; dropping is not. The
    # default is the reversible one because an audit log is the worst place in
    # the database to find out the horizon was set wrong. Switch to :drop once
    # something exports the detached partitions first.
    attr_accessor :retention_action

    # Consolidate a calendar year's twelve monthly partitions into one yearly
    # partition once the whole year is older than this. nil disables rollup.
    #
    # Two years back, so the window the auditor screens actually range over is
    # always still stored by month. Rolling up costs a full rewrite of the year
    # under an exclusive lock, and it coarsens retention -- a yearly partition
    # can only be retired whole, so up to eleven extra months are kept past the
    # horizon. Both are acceptable for cold years and neither is for warm ones.
    attr_accessor :rollup_after

    # Applied to every maintenance path that needs ACCESS EXCLUSIVE on an audit
    # table: drain_default!, retire!, and rollup_year!'s swap. A pending
    # ACCESS EXCLUSIVE request blocks every lock queued behind it, so an
    # unbounded wait behind one long reader stalls the audit write path for the
    # whole application. Fail fast and report instead.
    attr_accessor :maintenance_lock_timeout

    # How far either side of a request's own timestamp the drill-down looks for
    # the rows belonging to it. See AuditLog::RequestDrillDown: this exists to buy
    # partition pruning on a query that has no occurred_at predicate of its own.
    #
    # Generous on purpose. The bound is an optimization, and the failure mode of a
    # too-narrow one is an audit screen that quietly shows FEWER rows than really
    # exist -- far worse than a slow one. The long tail is a console session, which
    # holds one request_id open for as long as the operator stays logged in. Even
    # 24 hours prunes 84 monthly partitions to two.
    attr_accessor :drill_down_slack

    # See Engine's audit_log.event_subscriber initializer. True means a failed
    # audit_events write raises and rolls back the action it was describing,
    # rather than being swallowed by ActiveSupport::EventReporter.
    attr_accessor :raise_on_subscriber_error

    def initialize
      @stamped_databases        = %w[primary]
      @parent_controller        = "ApplicationController"
      @authorize                = ->(_controller) {}
      @actor_resolver           = ->(controller) { controller.try(:current_user) }
      @actor_picker             = ->(_query) { [] }
      @actor_finder             = ->(type, id) { type.to_s.safe_constantize&.find_by(id: id) }
      @actor_label_resolver     = ->(actor) { default_actor_label(actor) }
      @bypass_allowlist         = []
      @default_excluded_columns = DEFAULT_EXCLUDED_COLUMNS.dup
      @partition_months_ahead   = 3
      @drill_down_slack         = 24.hours
      @retention                = 7.years
      @retention_action         = :detach
      @rollup_after             = 2.years
      @maintenance_lock_timeout = "5s"
      @raise_on_subscriber_error = true
      @unaudited_tables         = {
        "schema_migrations"    => "Rails internal",
        "ar_internal_metadata" => "Rails internal",
        "audit_events"         => "the audit log itself",
        "audit_changes"        => "the audit log itself"
      }
    end

    private

    # Assumes only what a Devise-shaped User offers. `to_label` is the intended
    # hook -- define it on the actor model and the audit log renders it verbatim.
    # The fallbacks exist so an ApiKey or a Machine actor that never heard of
    # this library still produces something an auditor can read.
    def default_actor_label(actor)
      return actor.to_label if actor.respond_to?(:to_label)

      name  = actor.try(:name) || actor.try(:full_name)
      email = actor.try(:email)
      return "#{name} <#{email}>" if name && email
      return name || email if name || email

      "#{actor.class.name} ##{actor.id}"
    end
  end
end
