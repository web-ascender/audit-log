# Changelog

Notable changes to `audit_log`. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- **Dimensions — host-defined facets, so an app can ask "everything that happened
  to invoices in department 5".** A `dimensions jsonb` column on both audit
  tables, filled from two sources that mirror the two layers: the trigger reads
  declared COLUMNS off the row that changed, so facets reach `update_all`,
  `delete_all`, raw SQL, a database cascade and a console session; and
  `EventSubscriber` lifts declared KEYS out of a completed payload, so facets
  reach a unit of work whose writes landed in a table that declares none. A unit
  qualifies if either matched.

  ```ruby
  attach_audit_trigger :invoices, model: "Invoice", dimensions: %i[department_id]

  AuditLog::Registry.register "invoice.approved", dimensions: %i[region], ...
  config.default_dimensions = -> { { app_version: AppVersion.current } }
  ```

  Query with `AuditLog::DimensionTimeline`, which is `Timeline` with the record
  predicate swapped and yields the same `Activity` value objects, or with
  `where_dimensions` on either relation. `config.dimension_filters` adds a filter
  to the auditor UI at `/audit/dimensions`.

  **Entirely optional, and an application that declares no facet pays nothing.**
  The GIN index is partial on `dimensions IS NOT NULL`, so it excludes every row
  of every non-adopting table permanently and at write time; the trigger's
  extraction sits behind `TG_ARGV[2] IS NOT NULL`. The column itself costs
  `audit_events` nothing and `audit_changes` 8 bytes a row (+0.54% heap),
  measured and accepted so that there is one trigger function rather than two.

  **Three limits are documented rather than discovered**, because each is a screen
  that renders fine while answering a narrower question: it is not retroactive, a
  conjunction has to fit on one row, and a row is filed under the value it held
  *after* the change. `DimensionTimeline` is consequently the one query object
  bounded by default (30 days), and it discloses the bound.

  See the README's "Dimensions" section and DESIGN §23, which keeps the
  measurements and the rejected alternatives — an `OLD ∪ NEW` array encoding, an
  ambient GUC on the trigger, `dimensions: :auto`, and gating the column behind
  the opt-in migration.

- **`rails generate audit_log:dimensions`** — the retrofit path, for an
  application installed before the above. It adds the column, **re-installs the
  trigger function** so it reads facet lists, and builds the facet index one
  partition at a time with `CREATE INDEX CONCURRENTLY` (refused outright on a
  partitioned table), asserting the catalog's own `indisvalid` rather than
  counting partitions. Safe to re-run after an interruption. A new install needs
  none of it.

- **`AuditLog.audited(action, on:, **identity) { |audit| … }`** — sugar for the
  canonical layer-2 call site, `transaction do ... AuditLog.notify ... end`. It
  opens the transaction, runs the block, and emits as the last statement inside
  it, so both directions of R3 are unchanged: a raise never reaches the emit, and
  a failed emit rolls the writes back. Returns the block's value.

  **The payload is built in two slots.** Keyword arguments are evaluated before
  the block, which is right for identity and inputs and silently wrong for
  outcomes — a total recalculated by the block, a tracking number for a record it
  has not created yet. Those go through the yielded `AuditLog::Payload`
  (`audit[:k] = v`, `audit.merge!(k: v)`, `audit.merge!({…})`). A key set in both
  slots raises, with a message naming which one to remove it from.

  `AuditLog::Payload` wraps a Hash rather than subclassing one, so `delete`,
  `clear` and `replace` are not part of what a block may do to an audit payload.
  `merge` without the bang raises: Ruby's convention would have it build a hash
  and discard it, emitting the event without those keys.

  Purely additive. The explicit `transaction` + `notify` form is unchanged, not
  deprecated, and remains the option when several notifies belong to one
  transaction. See DESIGN §7 and the README.

- **`AuditLog.audited` now yields the `ActiveRecord::Transaction`** as a second
  block argument, accepts `transaction:` options passed through to
  `ActiveRecord::Base.transaction`, and raises on an `ActiveRecord::Rollback` it
  could not honour. It has always joined a caller's open transaction — that is
  the only way Rails allows one to be handed over — but a joined transaction
  swallows `ActiveRecord::Rollback`, and the sugar hides the nesting. Left
  unguarded that committed the writes, emitted no event, and returned `nil` as
  though it had rolled back. Yielding the transaction lets a caller use Rails'
  transaction callbacks without opening one of its own; when joined it is their
  transaction, so callbacks fire on their outermost commit.

- **`AuditLog::Registry.register requires:`** — an optional payload contract per
  action. The keys a call site passes and the `p[...]` reads in the entry were
  checked by nothing, and a typo on either side rendered a gap in a sentence that
  is frozen at emit time and can never be repaired. Declared, a missing key
  raises `AuditLog::MissingPayloadKeys` from `EventSubscriber#emit` — the one
  point `notify`, `audited` and a bare `Rails.event.notify` all cross, and inside
  the caller's transaction, so the change rolls back rather than committing
  beside a holed sentence.

  Opt-in per entry: without `requires:` an action behaves exactly as before, so
  the raise is only reachable where somebody wrote a contract. Extra keys pass
  and are still stored. The check is key presence, not value presence — a
  deliberate `nil` counts as supplied, since `metadata` is stored `.compact`ed
  and would otherwise be indistinguishable from a forgotten key.

## 0.3.0 — 2026-08-30

**Two configuration surfaces were quietly lying, and this release stops both.**
Neither failure raised, logged, or degraded a screen — the ordinary shape of an
under-report, which is the thing this library exists to prevent.

`config.correlated_databases` invited a *database* name where a **connection**
name was required. A real application was configured with one. Every trigger
still fired and every row was still written, all with a NULL actor and NULL
`request_id` — indistinguishable from a console session. It is now
`config.correlated_connections`, with no deprecated alias and a boot check that
refuses to start on a value matching nothing.

And the library assumed the `public` schema, in both directions. A trigger
function pinned to `public` filed every schema's rows in one table while the
writes succeeded; a provisioning check asking about `public.audit_changes_2026_08`
reported the work done to a caller provisioning somewhere else; and the catalog
queries that filtered on `relname` alone let one schema's trigger vouch for
another schema's table, so `rake audit_log:coverage` passed while a table went
unaudited. Everything now operates on `current_schema()`. **Nothing changes for a
single-schema application** — which is nearly all of them — because
`current_schema()` is `public`. No configuration was added and no tenancy library
is named: this is the removal of an assumption, not a new feature. DESIGN §14 is
rewritten accordingly.

Requires Ruby >= 3.3, Rails ~> 8.0, PostgreSQL >= 16.

### Changed — breaking

- **`config.correlated_databases` is now `config.correlated_connections`, with no
  deprecated alias.** An initializer that sets the old name raises
  `NoMethodError` at boot, which is deliberate: the value was being misread, and
  a silent alias would preserve the misreading.

  It takes **connection** names as they appear in `database.yml` (`primary`,
  `queue`) and is compared against `connection.pool.db_config.name`. The old name
  invited a *database* name, and a real app was configured with one. Nothing
  raised — every trigger still fired and every row was still written, all with a
  NULL actor and NULL `request_id`, indistinguishable from a console session. An
  app can run that way for months and find out when an auditor asks who did
  something. That is the under-report this library exists to prevent, reached
  through its own configuration.

  **Most apps should delete the line rather than rename it.** The default
  `%w[primary]` is correct for any single-database app, *including one whose
  `database.yml` has no `primary:` key* — Rails names a flat config `primary`.
  Set it only for a multi-database app that audits tables outside the primary
  connection.

### Added

- **`spec/audit_log/schema_isolation_spec.rb`** installs the library into a bare
  second schema and asserts where the rows land, including that a table in
  another schema keeps its own audit trail and that shadowing `audit_changes`
  into an earlier `search_path` entry cannot redirect a write. Seven of its
  eight examples fail against the previous behaviour. It uses no tenancy gem —
  a second schema and a `search_path` is all this library is entitled to know
  about.
- **`AuditLog::Schema.function_sql` and `.qualified_function_name`** are public,
  so a host app can see what it is about to install.
- **A boot check.** `Configuration#verify_correlated_connections!` raises when
  the configured names match no connection at all, and warns on a partial miss —
  `%w[primary replica]` is legitimate in an app whose test environment has no
  replica, so raising there would refuse to boot a correct configuration. The
  error names both what was configured and what is available.
- **`correlation_spec` pins the assumption the default rests on**: that Rails
  normalizes a flat, single-database `database.yml` to the name `primary`. If
  that ever changed, every adopter on a flat config would silently stop
  correlating, and nothing else would say so.

### Fixed

- **The trigger function is installed into the current schema and names its
  destination in full**, rather than being `public.audit_row_change` pinned to
  `SET search_path = pg_catalog, public` and writing to an unqualified
  `audit_changes`. `attach_audit_trigger` now references the function
  unqualified, so `CREATE TRIGGER` binds permanently to the copy installed
  alongside it by the same migration run.

  **Nothing changes for a single-schema application** — `current_schema()` is
  `public`, one copy of the function is installed, and the emitted DDL is
  equivalent. In an application whose `search_path` is not `public` the old
  behaviour was wrong in the worst available way: `audit_tables.sql` creates its
  tables unqualified, so they followed `search_path` into the current schema
  while every row the triggers wrote went to `public`. The writes succeeded.
  Nothing reported anything.

- **`AuditLog::Partitions.exists?` no longer asks `to_regclass('public.' ||
  name)`.** Provisioning a second schema found `public`'s partition, reported
  the work already done, and created nothing — leaving a parent with no
  partitions at all, which then failed on its first audited write with `no
  partition of relation "audit_changes" found for row`.

- **`Partitions.attached?`, the three partition inventory queries, both
  `AuditLog::Coverage` queries and three `audit_log:benchmark` queries are
  scoped to `current_schema()`.** They filtered on `relname` alone, so they saw
  every schema's objects at once. For `Coverage` that is the whole ballgame: one
  schema's trigger vouched for another schema's table and the forcing function
  passed while a table went unaudited.

  This adds no configuration and names no tenancy library. It is the removal of
  an assumption, not the addition of a feature — see DESIGN §14, which was
  rewritten and whose previous advice recommended the shared-function
  arrangement this replaces.

- **The Rails 8.0 CI gap is closed**, and it was a real gap rather than a
  formality. `rails: ["8.0", "latest"]` joins the Ruby and PostgreSQL floor legs
  on the same argument: a floor nothing runs against is a guess. It found one
  breakage on the first run — `spec/dummy` pinned `config.load_defaults 8.1`,
  which raises `Unknown version "8.1"` on Rails 8.0 before an example loads — and
  a second that only CI could see: the dummy app's migrations were declared
  `ActiveRecord::Migration[8.1]`, which Rails 8.0 rejects, invisible locally
  because an already-migrated database never loads the file. The library itself
  needed no change; the install and trigger generators already emit the adopter's
  own `ActiveRecord::Migration.current_version`.
- **`AuditLog.notify`'s fallback for the absent `Rails.event` is now exercised.**
  Rails 8.0 has no event reporter, so the floor takes a different branch than the
  development version — and it was the branch nothing ran. `event_transport_spec`
  asserts which branch each Rails takes, in both directions, so the leg proves
  the fallback works rather than that nothing raised.

`latest` is unpinned on purpose: it is the newest Rails the gemspec admits, so
8.2 is tested the day it ships. Six legs, not eight — Rails 8.0 runs at every
floor at once (Ruby 3.3 / PG 16) and on the development pair (4.0.6 / PG 18).

## 0.2.0 — 2026-08-30

**`pagy` is no longer a dependency.** `AuditLog::Pagination` is unchanged in shape
— `include` it, call `paginate(scope, limit:)`, read `records` and `next` — and is
now this library's own keyset pager rather than a wrapper over `Pagy::Keyset`.

The reason is the host application, not Pagy. Bundler resolves one `pagy` per app;
keyset paging exists in Pagy from 9.0 and the `jsonify_keyset_attributes:` hook
that `FULL_PRECISION` cannot work without only from 9.3, and Pagy 43 removed that
hook again. The only honest dependency was therefore `~> 9.3` — two releases — and
it propagated into every adopter's own pagination: an app on Pagy 5, or on current
Pagy, could not install 0.1.0 at all. Nothing here ever used Pagy's frontend.
DESIGN §11.0 carries the amendment.

### Changed

- **`pagy` removed from the gemspec.** The one runtime dependency besides `rails`
  is now `csv`. Paginate the rest of your app with anything, or nothing.
- **`@pagy` renamed to `@page`** in the engine's controllers and views, in the
  `audit_log:views:activity` templates, and in the README. If you generated the
  activity views under 0.1.0 they are yours and keep working — the rename is not
  applied to files you already own, and `@pagy` is still a valid ivar name.
- **A non-column ordering now raises `Pagination::InvalidCursor`** and falls back
  to the newest page, where it previously raised `NoMethodError` on an
  `Arel::Nodes::SqlLiteral` and took the screen down.

### Unchanged

Rule 2 itself, every screen, the cursor format, and all four properties DESIGN
§11.0 lists — including the microsecond cursor, which `pagination_spec` still
pins with six rows inside one millisecond.

## 0.1.0 — 2026-08-30

First release. There is deliberately no history before this entry: the library
was developed as `lib/audit_log/` inside the reference application and extracted
into a gem, and none of that predates a version anybody could have installed.

- **Layer 1** — PostgreSQL `AFTER ... FOR EACH ROW` triggers write a jsonb
  field-level diff of every INSERT, UPDATE and DELETE to `audit_changes`.
  `update_all`, `delete_all`, `insert_all`, `upsert_all`, a database cascade, raw
  SQL, a rake task and a console session are all captured. Nothing goes in a
  model class.
- **Layer 2** — `AuditLog.notify` emits a registered action; one durable
  subscriber writes a human-readable row to `audit_events`. Joined to layer 1 by
  a UUIDv7 `request_id`, one per unit of work.
- **Actor propagation** through web requests, background jobs (with the
  originating request as `caused_by_request_id`), and the console.
- **`AuditLog::Coverage`** and a shared RSpec example, so a table that is neither
  audited nor exempted *with a written reason* fails the build.
- **An auditor UI at `/audit`**, served by the engine: actor activity, record
  history in three tabs, action reports, out-of-band review, request drill-down,
  CSV export.
- **`AuditLog::Timeline`** — a published, host-facing contract of value objects
  for rendering one record's history in your own app, plus
  `rails generate audit_log:views:activity` to install starter views for it.
- **`AuditLog::Pagination`** — keyset paging with a microsecond cursor, host-facing.
- **Storage lifecycle** — monthly range partitions, daily rotation and freezing,
  default-partition drain, yearly rollup, retention that detaches and never
  drops, and verified gzipped-CSV export before disposal.
- **`AuditLog::Redaction`** — GDPR erasure that removes values and keeps
  structure, and narrates itself in the same transaction.
- **Generators** — `audit_log:install`, `audit_log:trigger`,
  `audit_log:views:activity`.
- **Zero application constants.** Every coupling point is a lambda or string on
  `AuditLog.config`.

Requires Ruby >= 3.3, Rails ~> 8.0, PostgreSQL >= 16. CI runs the suite on Ruby
3.3 and 4.0.6 against PostgreSQL 16 and 18.

### Known gaps

- **No Rails 8.0 CI leg.** The gemspec claims `~> 8.0` but CI tests 8.1 only, so
  `AuditLog.notify`'s documented fallback for the absence of `Rails.event` is
  untested at the floor.

---

[`DESIGN.md`](DESIGN.md) is the record of *why* anything here is shaped the way
it is, and is where design amendments are written down. This file records what
changed between released versions; for anything finer, read the git history.
