# frozen_string_literal: true

# The durations below (24.hours, 7.years) are core_ext, not core Ruby. Inside a
# booted Rails app something else has always required this already; as a GEM,
# depending on that transitively is how `require "audit_log"` comes to work only
# when the Gemfile happens to load ActiveRecord first.
require "active_support/core_ext/numeric/time"   # 24.hours
require "active_support/core_ext/integer/time"   # 7.years, 2.years

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

    # Databases whose connections carry the audit correlation context -- the
    # audit.request_id and audit.actor_* settings the trigger reads.
    #
    # Named for what it gates, because what it does NOT gate is the thing readers
    # get wrong: this decides who pays for correlation, never what is audited.
    # Auditing is opt-in per TABLE, through attach_audit_trigger. A database left
    # out of this list is still audited exactly as before -- every trigger still
    # fires and every row is still written; those rows simply arrive with a NULL
    # request_id and NULL actor, indistinguishable from a console session. The
    # trigger's only early exit is audit.bypass.
    #
    # Solid Queue's database is deliberately absent. TransactionStamp is prepended
    # onto the adapter CLASS, so it is live on every connection in the process
    # regardless of database; without this list it would fire on every poll, claim
    # and heartbeat -- the busiest transaction path in the system. Plan §6.4.
    # CONNECTION names, as Rails names them -- `primary`, `queue` -- and NOT
    # database names. `AuditLog::Context.stamped_database?` compares against
    # `connection.pool.db_config.name`, so `ngen_ipc_production` here matches
    # nothing and silently switches correlation off. The old name for this,
    # `correlated_databases`, invited exactly that and cost a real app a
    # debugging session; `Engine`'s boot check now refuses it outright.
    #
    # The default is right for nearly every app, INCLUDING one whose
    # database.yml has no `primary:` key at all: Rails normalizes a flat,
    # single-database config to the name "primary". Change this only for a
    # multi-database app that audits tables outside the primary connection.
    attr_accessor :correlated_connections

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
    #
    # The default tries `to_audit_label`, then `to_label`, then name/email, then
    # "Class #id" -- the same head as AuditLog::RecordLabel's chain, so one hook
    # answers "what should auditors see" wherever a model appears in the log.
    attr_accessor :actor_label_resolver

    # ->(type, ids) { {id => label} }  Turns record ids into the labels an auditor
    # reads NEXT TO them on a diff -- "Grommet 10mm (id: 51)". Display-time only;
    # nothing it returns is ever stored, which is what separates it from
    # actor_label_resolver above. See AuditLog::RecordLabel for why that is safe.
    #
    # Batch, not per-id: called once per record type per page. Return nil for a
    # type you do not label, and {} for a type you do label none of whose ids
    # exist any more -- the screen renders those two differently.
    #
    # nil disables association labelling entirely, and every screen renders bare
    # ids exactly as it did before the feature existed.
    #
    # SCOPING IS THE HOST APP'S JOB. The default reads business tables with no
    # tenant scope, on a screen an auditor is trusted with. `where(id: ids)` reads
    # perfectly safe and is not, in a multitenant application. Scope it here.
    attr_accessor :record_label_resolver

    # { "LineItem" => { "product_id" => "Product" } }
    #
    # Which diff columns are association ids, for the ones belongs_to reflection
    # cannot see. Merged OVER the reflected map, so an entry here wins; `false`
    # suppresses a column that reflection did find.
    #
    # Holds no labels -- only the record type each column points at. Reflection
    # covers the ordinary case and is the reason there is no convention-based
    # fallback: `created_by_id`.sub(/_id$/, "").classify is "CreatedBy", and a
    # convention that silently mislabels is worse than one that says nothing.
    attr_accessor :association_targets

    # ->(type, id) { } -> a path/URL string, or nil.
    #
    # Where the HOST app shows the record `type`/`id` names, for a timeline it
    # renders on its own pages: the "also touched" list, and the actor on an
    # entry. Nothing in this library calls it for its own screens -- the auditor
    # UI links into the auditor UI.
    #
    # It defaults to nil and the default is not a placeholder. This gem does not
    # know the host's routes, and inferring one from a class name
    # ("Product" -> product_path) is the same mistake as sniffing a `name` column
    # for a label: a confident wrong link on an audit screen is worse than no
    # link, and it fails at RENDER time on a screen an auditor is reading. Same
    # discipline as AuditLog::RecordLabel's chain ending in nil -- silence is the
    # opt-out, and the value objects render fine without it.
    #
    # Return nil for a type the app has no page for, and for a record the current
    # viewer may not open: this library does not know who is looking.
    #
    #   config.record_url = lambda do |type, id|
    #     case type
    #     when "Order"   then Rails.application.routes.url_helpers.order_path(id)
    #     when "Product" then Rails.application.routes.url_helpers.product_path(id)
    #     end
    #   end
    attr_accessor :record_url

    # Classes permitted to call AuditLog.without_logging. Empty array means the
    # bypass is unavailable, which is the right default.
    attr_accessor :bypass_allowlist

    # Added to DEFAULT_EXCLUDED_COLUMNS above rather than replacing it, unless a
    # host app deliberately reassigns. Per-table exclusions belong in the
    # migration; this is the floor that applies everywhere.
    attr_accessor :default_excluded_columns

    # -> { { tenant_id: Current.tenant&.id, app_version: AppVersion.current } }
    #
    # AMBIENT FACETS: recorded onto EVERY audit_events row, merged UNDER whatever
    # a registry entry declared, so a call site wins on any overlap. For the
    # constants that have no business being repeated at a thousand call sites --
    # the current tenant, the deployed version, a region. DESIGN §23.
    #
    # IT TAKES NO ARGUMENTS AT ALL, and that is what makes this and a registry
    # entry's `dimensions:` two different things rather than two spellings of
    # one. Nothing downstream can distinguish a key this lambda supplied from one
    # the registry lifted -- identical jsonb, same column, same table -- and
    # nothing should be able to. The distinction is entirely in where the value
    # is READ FROM, and therefore in what it can vary with: the registry reads the
    # PAYLOAD, so its facets differ between two events of the same action; this
    # reads APPLICATION STATE, so its facets are identical for every event in a
    # unit of work. Hand it the payload and that collapses into a registry
    # declaration applied globally with worse discoverability.
    #
    # Two things follow from taking nothing and neither is available otherwise.
    # It is a GUARANTEE that two events in one unit of work cannot disagree about
    # the tenant. And a value that cannot depend on the event is computed ONCE
    # PER UNIT OF WORK and memoised on Current, rather than once per event.
    #
    # An action name would let the ambient set vary per action -- but per-action
    # facets already have a home, in the registry entry beside that action's
    # `summary` and `requires:`, where anybody reviewing the finite list of
    # auditable actions can see them. A `case action when ...` in this lambda is
    # the same information moved somewhere strictly worse.
    #
    # NAMED FOR `default_excluded_columns` one feature over, whose own comment
    # calls it "the floor that applies everywhere". This is that shape exactly,
    # and `default` is literally accurate rather than approximate, because the
    # merge really does let a declared key win. `ambient` names the property more
    # precisely and is a term a reader would have to learn first.
    #
    # IT MUST NOT RAISE, and if it does the event is still written with whatever
    # was gathered -- logged, never re-raised. The precedent split is principled:
    # `requires:` and raise_on_subscriber_error roll the transaction back because
    # they protect the TRAIL; LabelResolver logs and renders FAILED because it is
    # display. A dimension is a convenience, so it follows LabelResolver. Rolling
    # back an approved invoice because an app-version lookup raised would be
    # indefensible.
    #
    # WHAT IT COSTS, measured: three ambient keys on every event is +32.5% on
    # audit_events insert and +23% heap -- roughly half the jsonb value, half the
    # GIN entry. audit_events is the low-volume table, so at a typical 1:5
    # event-to-change ratio that lands near +5% of total audit write cost.
    # Declare only what will be FILTERED on; a value merely read on a screen
    # belongs in the payload, which is free.
    attr_accessor :default_dimensions

    # { customer_id: { label: "Customer", options: -> { [[name, id], ...] } } }
    #
    # Which facets the auditor UI offers as a filter. INERT: nothing here affects
    # what is recorded, and forgetting it costs a missing filter that can be added
    # later with no effect on a single stored row.
    #
    # IT IS `dimension_filters` AND IT WAS NEARLY `dimensions`. That spelling
    # reads like this library's DECLARATIVE options -- unaudited_tables,
    # association_targets, bypass_allowlist -- plural nouns stating a fact the
    # library then acts on. This one states nothing and acts on nothing, while the
    # option directly above it writes data onto every event permanently and
    # non-retroactively. Consequence and appearance inverted, which is the mistake
    # correlated_databases made before it became correlated_connections. `filters`
    # carries the distinction with no prefix: three settings in this feature are
    # named `dimensions` and all three record data; one is named `filters` and
    # does not.
    #
    # `options:` follows actor_picker exactly, and for the reason that option's
    # own comment gives: populate a picker from the HOST's own table, never from
    # SELECT DISTINCT dimensions->>'customer_id' over a partitioned audit table,
    # which is unusable at volume. No `options:` means a free-text input --
    # honest, zero coupling, and correct for something like app_version where the
    # host may have no list to offer.
    #
    # Empty by default, and the auditor UI hides the screen entirely when it is:
    # a nav item leading to a filter with nothing to filter by is worse than no
    # nav item. Same discipline as record_url defaulting to nil.
    attr_accessor :dimension_filters

    # Tables that legitimately have no audit trigger. The coverage spec fails the
    # build for any table in the primary database that is neither audited nor
    # listed here, so every exemption carries a written reason.
    attr_accessor :unaudited_tables

    # Rows per page on the auditor screens. Keyset-paginated, so this is a
    # rendering choice with no cost curve behind it -- there is no OFFSET to
    # grow and no count to compute. See AuditLog::Pagination.
    attr_accessor :page_size

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

    # Consolidate a calendar year's twelve monthly partitions into one yearly
    # partition once the whole year is older than this. nil disables rollup.
    #
    # Two years back, so the window the auditor screens actually range over is
    # always still stored by month. Rolling up costs a full rewrite of the year
    # under an exclusive lock, and it coarsens retention -- a yearly partition
    # can only be retired whole, so up to eleven extra months are kept past the
    # horizon. Both are acceptable for cold years and neither is for warm ones.
    attr_accessor :rollup_after

    # Where `rake audit_log:export` writes retired partitions. A LOCAL path: the
    # library streams the partition to a file and stops. Moving that file to S3,
    # GCS or anywhere else is a deployment decision, and baking one in is what
    # would stop this being copyable. See AuditLog::Archive.
    attr_accessor :archive_dir

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

    # Refuse a correlated_connections that names nothing real. Called from the
    # engine at after_initialize; a method rather than a block in the initializer
    # so a spec can exercise the decision instead of re-deriving it.
    #
    # THE FAILURE THIS EXISTS FOR IS SILENT. The value is compared against
    # `connection.pool.db_config.name`, so a plausible database NAME
    # ("ngen_ipc_production") matches no connection and nothing raises: every
    # trigger still fires and every row is still written, all of them with a NULL
    # actor and NULL request_id, indistinguishable from a console session. An app
    # can run that way for months and find out when an auditor asks who did
    # something. That is the exact under-report this library exists to prevent,
    # so it must not be reachable through its own configuration.
    #
    # RAISES only when NOTHING matches -- correlation is then entirely off and no
    # reading of that is intentional. An individual name that matches nothing
    # only warns, because `%w[primary replica]` is legitimate in an app whose
    # test environment has no replica; raising there would refuse to boot a
    # correct configuration.
    def verify_correlated_connections!(known)
      configured = Array(correlated_connections).map(&:to_s)
      known      = Array(known).map(&:to_s)

      if (configured & known).empty?
        raise AuditLog::Error, <<~MESSAGE
          config.correlated_connections names no connection in this application.

            configured: #{configured.inspect}
            available:  #{known.inspect}

          These are CONNECTION names as they appear in database.yml -- `primary`,
          `queue` -- not database names. Left as it is, every audited write would
          still be recorded but would arrive with a NULL actor and NULL request_id.

          Nearly every app wants the default, %w[primary], including one whose
          database.yml has no `primary:` key: Rails names a flat single-database
          config "primary". Set this only for a multi-database app that audits
          tables outside the primary connection.
        MESSAGE
      end

      unknown = configured - known
      return [] if unknown.empty?

      Rails.logger&.warn(
        "[AuditLog] config.correlated_connections names #{unknown.inspect}, which match no " \
        "connection in this environment (available: #{known.inspect}). Writes on those " \
        "connections will carry no actor or request_id."
      )
      unknown
    end

    def initialize
      @correlated_connections   = %w[primary]
      @parent_controller        = "ApplicationController"
      @authorize                = ->(_controller) {}
      @actor_resolver           = ->(controller) { controller.try(:current_user) }
      @actor_picker             = ->(_query) { [] }
      @actor_finder             = ->(type, id) { type.to_s.safe_constantize&.find_by(id: id) }
      @actor_label_resolver     = ->(actor) { default_actor_label(actor) }
      @record_label_resolver    = ->(type, ids) { AuditLog::RecordLabel.batch(type, ids) }
      @association_targets      = {}
      @bypass_allowlist         = []
      @default_excluded_columns = DEFAULT_EXCLUDED_COLUMNS.dup
      @record_url               = nil
      @default_dimensions       = nil
      @dimension_filters        = {}
      @page_size                = 50
      @partition_months_ahead   = 3
      @drill_down_slack         = 24.hours
      @retention                = 7.years
      @rollup_after             = 2.years
      @maintenance_lock_timeout = "5s"
      @archive_dir              = nil
      @raise_on_subscriber_error = true
      @unaudited_tables         = {
        "schema_migrations"    => "Rails internal",
        "ar_internal_metadata" => "Rails internal",
        "audit_events"         => "the audit log itself",
        "audit_changes"        => "the audit log itself"
      }
    end

    private

    # Assumes only what a Devise-shaped User offers. `to_audit_label` and
    # `to_label` are the intended hooks -- define either on the actor model and
    # the audit log renders it verbatim. The fallbacks exist so an ApiKey or a
    # Machine actor that never heard of this library still produces something an
    # auditor can read.
    #
    # `to_audit_label` comes first, the same order and for the same reason as
    # AuditLog::RecordLabel: it lets a model say something to auditors other than
    # what it says to the rest of the UI. That matters MORE here than it does
    # there. A record label is resolved live at display time and annotates an id
    # that stays on the screen beside it; this one is SNAPSHOTTED onto every audit
    # row at the moment of the change and is the only identity that column will
    # ever carry. A `to_label` that embeds a customer-facing string, a phone
    # number or an internal ticket URL is a reasonable everyday label and a poor
    # thing to freeze across seven years of audit trail, and before this the only
    # way to separate the two was to replace the resolver wholesale.
    #
    # The chains still diverge at the END, and that divergence is the deliberate
    # one (DESIGN §11.8): RecordLabel's terminates in nil so the feature is opt-in
    # and an unlabelled cell renders the bare id, while this one must terminate in
    # something because the actor column would otherwise be blank.
    def default_actor_label(actor)
      return actor.to_audit_label if actor.respond_to?(:to_audit_label)
      return actor.to_label if actor.respond_to?(:to_label)

      name  = actor.try(:name) || actor.try(:full_name)
      email = actor.try(:email)
      return "#{name} <#{email}>" if name && email
      return name || email if name || email

      "#{actor.class.name} ##{actor.id}"
    end
  end
end
