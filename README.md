# AuditLog

A two-layer, compliance-grade audit log for Rails 8 + PostgreSQL. Implements
[`AUDIT_LOGGING_PLAN.md`](../../AUDIT_LOGGING_PLAN.md) — the design document, which lives at
the application root and is the authority on *why* any of this is shaped the way it is.

This directory plus `lib/audit_log.rb` are the **entire library**. Nothing in it
references an application constant, an authentication gem, or a model name —
every coupling point is a lambda on `AuditLog.config`. It is structured as a
`Rails::Engine` so that extracting it into a gem is a `gemspec` away.

---

## The two layers

```
                         Current.request_id = <uuidv7>
   web request           Current.actor      = User#17
   background job                 │
   console / rake                 │
                     ┌────────────┴────────────┐
                     │                         │
        LAYER 2 (application)      LAYER 1 (PostgreSQL)
        AuditLog.notify(...)       AFTER INSERT/UPDATE/DELETE
                │                  FOR EACH ROW triggers
                ▼                         │
          audit_events   ◄─request_id─►   ▼
          1 row per ACTION           audit_changes
          who / what / summary       1 row per ROW CHANGE
                                     jsonb field diff
```

**Layer 1** cannot be bypassed. Not by `update_all`, `delete_all`, `insert_all`,
`upsert_all`, `dependent: :delete_all`, a database cascade, raw SQL, a rake task,
or a console session — because it lives in the database rather than in an
Active Record callback. This is the whole reason for the design.

**Layer 2** is opt-in per action, because no database can infer that saving six
rows constituted "submitting an order".

**The join is `request_id`.** One form submit → one `audit_events` row → N
`audit_changes` rows sharing one UUIDv7.

---

## Installing into another Rails 8 app

1. Copy `lib/audit_log.rb` and `lib/audit_log/` into the target app's `lib/`.

2. In `config/application.rb`, **before** the `class Application` body:

   ```ruby
   require_relative "../lib/audit_log"
   ```

   `require_relative`, not `require`: Rails has not yet put `lib` on `$LOAD_PATH`
   at this point in boot.

3. In the `Application` body:

   ```ruby
   # Zeitwerk must not also claim the engine's constants.
   config.autoload_lib(ignore: %w[assets tasks audit_log])

   # REQUIRED, and required before the first migration exists: schema.rb cannot
   # represent partitioned tables, trigger functions, or triggers.
   config.active_record.schema_format = :sql
   ```

4. `config/initializers/audit_log.rb` — configure the coupling points and
   register actions. See this demo's copy for a worked example.

5. Migration:

   ```ruby
   class InstallAuditLog < ActiveRecord::Migration[8.1]
     def up   = AuditLog::Schema.install!(connection)
     def down = AuditLog::Schema.uninstall!(connection)
   end
   ```

6. Attach a trigger per audited table, in the migration that creates it:

   ```ruby
   create_table :orders { |t| ... }
   attach_audit_trigger :orders, model: "Order"
   ```

7. `ApplicationController`: `include AuditLog::ControllerContext`
   (after whatever establishes `current_user`).

8. `ApplicationJob`: `include AuditLog::JobContext`.

9. `config/routes.rb`: `mount AuditLog::Engine => "/audit", as: :audit`.

10. Copy the specs in `spec/audit_log/` — especially `coverage_spec.rb`.

11. Schedule `AuditLog::Partitions.ensure!` daily. **A missing future partition
    is a write-path outage**, not a degraded report. Nothing else in
    `partitions.rb` belongs in a cron — see
    [The partition lifecycle](#the-partition-lifecycle).

### What a model needs

Nothing. No `has_audit_log`, no `include Auditable`, no callback, no base class.
An audited model is an ordinary `ApplicationRecord`. The one line of per-model
cost lives in the migration, next to the table it audits.

---

## Files

| Path | Role |
|---|---|
| `configuration.rb` | Every host-app coupling point. The only file to read before adopting. |
| `current.rb` | `CurrentAttributes` holding the audit identity as **primitives**. |
| `context.rb` | Writes the correlation GUCs onto a connection; mints UUIDv7 ids. |
| `transaction_stamp.rb` | Adapter prepend. Read the comment — it explains why `raw_execute` and not `begin_db_transaction`. |
| `controller_context.rb` | The whole web integration. |
| `job_context.rb` | The whole background-job integration. |
| `registry.rb` | The allowlist of auditable actions, and each one's human sentence. |
| `event_subscriber.rb` | `Rails.event` → `audit_events`. |
| `actor_label.rb` | Renders the label that gets snapshotted onto every row. |
| `migration_helpers.rb` | `attach_audit_trigger` / `detach_audit_trigger`. |
| `schema.rb` | `install!` / `uninstall!` for a migration. |
| `partitions.rb` | Partition rotation, default-partition drain, yearly rollup, retention, freezing, UTC-boundary enforcement. |
| `bypass.rb` | The one escape hatch, which logs itself. |
| `console.rb` | Narrates console sessions. |
| `db/sql/audit_tables.sql` | The two partitioned tables and their indexes. |
| `db/sql/audit_row_change.sql` | The trigger function. The heart of layer 1. |
| `app/queries/` | One object per auditor question (`ActorActivity`, `RecordHistory`, `ActionReport`, `Reconciler`). |
| `app/controllers/`, `app/views/` | The auditor UI. |
| `tasks/audit_log.rake` | `partitions`, `drain_default`, `rollup`, `retention`, `freeze`, `reconcile`, `coverage`, `benchmark`. |

---

## Working on the library: what reloads and what does not

The engine loads its own files two ways, and only one of them reloads in
development:

| Path | Loader | Reloads? |
|---|---|---|
| `lib/audit_log/app/**` (queries, models, controllers, helpers, views) | Zeitwerk | **yes** |
| `lib/audit_log/*.rb` (`configuration`, `context`, `partitions`, `schema`, …) | `Kernel#autoload`, from `lib/audit_log.rb` | **no** — once per process |

**Editing anything directly under `lib/audit_log/` requires a server restart.**
This is deliberate, not an oversight: `lib/audit_log.rb` uses plain `autoload`
with absolute paths because it is required from `config/application.rb`, *before*
Rails' `:set_load_path` initializer runs, and `TransactionStamp` is `prepend`ed
into the Postgres adapter at boot, which reloading would corrupt. `AuditLog.config`
is memoized in `@config` on the module besides, so a reloaded `Configuration`
class would not replace the instance already built.

The failure mode is a half-updated library: a reloaded query object calling a
stale `Configuration`. Adding a `config` attribute and using it in the same edit
raises `NoMethodError` on the next request, which is the *good* case — if the
calling code tolerates `nil`, the same staleness silently changes behaviour
instead. Restart after touching the top level.

## Design decisions that are easy to get wrong

**`raw_execute`, not `begin_db_transaction`.** Transaction start looks like the
natural hook for a transaction-local setting, and it captures every `save` and
`destroy`. But `update_all` and `delete_all` open no transaction, so they would
be audited with a **NULL actor** — the log would record that a bulk change
happened and be unable to say who did it. Stamping at the statement level covers
both. The memo means the round trip happens about once per request, not once per
statement.

**The memo is cleared on rollback.** A session-level `SET` inside a transaction
is reverted by `ROLLBACK`, so the connection would otherwise believe a stamp is
in force that the server has discarded — and the resulting misattribution points
at whoever acted *before* the rollback.

**`changed_columns text[]` rather than a GIN index on `diff`.** A
`jsonb_path_ops` GIN index does not support the `?` key-existence operator at
all, so "which changes touched `status`" silently degrades to a sequential scan.
(And in Active Record `?` is a bind placeholder, so the operator has to be
written `??`.) A GIN index on a `text[]` of column names sidesteps both, indexes
smaller, and doubles as the display list.

**`actor_label` is a snapshot, not a join.** If the UI joined live to `users`,
renaming or deleting a user would retroactively change what the audit record
*says happened*. Auditors read that as tampering. A nil actor stores NULL, and
the UI renders "System" at display time — so an out-of-band write stays
distinguishable from a genuine system action.

**`readonly?` is keyed on `persisted?`, not hardcoded `true`.**
`ActiveRecord::Persistence#create_or_update` raises `ReadOnlyRecord` for inserts
too, so a flat `true` breaks the event subscriber. Keying on `persisted?` gives
exactly the intended rule: insert, never update or destroy.

**`Rails.event.raise_on_error = true`.** `ActiveSupport::EventReporter` rescues
subscriber exceptions and reports them as `handled: true`. For an observability
subscriber that is right; for this one it would mean the narrative row silently
vanishes while the change rows it describes commit anyway.

**`enqueue_after_transaction_commit` is set on the job class.** Setting
`config.active_job.enqueue_after_transaction_commit` in `application.rb` does
nothing — ActiveJob's railtie explicitly filters that key out of the global
config.

**The job origin is captured in `serialize`, not `around_enqueue`.**
`perform_all_later` and Solid Queue's `enqueue_all` skip enqueue callbacks, so an
`around_enqueue` hook would silently drop the actor on every bulk enqueue.

**Jobs inherit the actor but mint a fresh `request_id`**, recording the original
as `caused_by_request_id`. Inheriting the id instead would make a bulk job's
500k rows appear as children of one click, and would make retries
indistinguishable from each other.

---

### Short request ids use the TRAILING group, never a prefix

`audit_short_id` renders the last group of the uuid. Truncating from the front
looks natural and is wrong here: a UUIDv7's first 48 bits are the millisecond it
was minted, so `request_id.first(8)` keeps 32 of those bits, drops the low 16, and
has a resolution of about **65 seconds**. Every action in the same minute rendered
identically — which on a record-history screen, where consecutive actions are
seconds apart, is the common case rather than an edge one.

The failure is silent: the page renders, the links work, and two unrelated actions
merely look like the same one. Prefix truncation is a habit from v4 ids, whose
leading bits are random; in v7 they deliberately are not.

The trailing group is 48 bits of `rand_b`, and it costs nothing to use — the
timestamp half is redundant with the "When" column beside it on every screen that
renders this. The full id rides along in a `title` attribute.

### `caused_by_request_id` is a column, not a metadata key

`request_id` and `caused_by_request_id` answer different questions and are never
equal on the same row:

| | |
|---|---|
| `request_id` | *which unit of work wrote this row.* Shared by every row of one request or one job execution. |
| `caused_by_request_id` | *which earlier unit of work caused this one to exist.* A pointer to a **different** unit of work. |

The tempting design — have the job inherit its enqueuer's `request_id` — is what
the pair exists to avoid. It breaks in three ways (plan §6.4): a bulk job expands
one line in the actor's timeline into 500k children; retries become
indistinguishable; and, because the job runs later than the id was minted, the
id's timestamp stops bounding its rows, which destroys the pruning that
`RequestDrillDown` depends on. A fresh id per execution plus an explicit pointer
keeps all three.

It was originally stored inside `metadata`, which had two costs. The screen's
"what did this cause?" query was `metadata ->> 'caused_by_request_id' = ?` with no
index on `metadata` — a sequential scan of every partition of `audit_events`, on
every drill-down page load, making plan §6.4's "one indexed lookup" claim false.
And `metadata` holds the **action's** payload, so a registered action carrying its
own `caused_by_request_id` key silently overwrote the framework's.

It is now a real `uuid` column with a partial index
(`caused_by_request_id, occurred_at DESC WHERE caused_by_request_id IS NOT NULL` —
partial because only job-originated events carry a cause). `RequestDrillDown#caused_events`
bounds it with the same window as everything else.

**Demo data has to respect causality.** The seeds backdate rows, and doing that
per-row scattered one action's rows across days and placed effects before their
causes. `db/seeds.rb` now shifts **once per `request_id`** and has an effect adopt
its cause's shift.

### The drill-down carries a date bound derived from the `request_id`

`WHERE request_id = ?` names the partition key nowhere, so the planner cannot
eliminate a single partition. That is the one auditor query with no `occurred_at`
predicate of its own, and its cost grows linearly with the retention horizon —
six partitions today, 84 at seven years, on a hot UI path.

`AuditLog::RequestDrillDown` supplies the missing bound, preferring:

1. **An exact anchor.** Drilling down from an `audit_events` row means its
   `occurred_at` is already in hand (`Event#drill_down`). Free, exact, assumes
   nothing.
2. **The id itself.** `request_id` is a UUIDv7, whose first 48 bits are the
   milliseconds at which it was minted, so `Context.minted_at` recovers the bound
   from the value already being filtered on — no extra column, no schema change.
3. **No bound**, when the id is not a v7 UUID. `Context.minted_at` returns `nil`
   rather than decoding random v4 bits into a plausible-looking timestamp
   somewhere in the next half-million years.

Measured: 6 partitions → 1, with identical results.

**Why the window can be tight at all** is not an accident. A `request_id`'s
lifetime is one request or one job execution, because jobs deliberately do *not*
inherit the id of the request that enqueued them. Had they inherited it, a job
running three days later would write rows under an id minted three days earlier
and the window would have to span the whole retention horizon — that is, no
pruning. A decision made for timeline readability is the precondition for this
optimization.

**The risk, and how it is handled.** A too-narrow window shows *fewer* rows than
exist, and quiet under-reporting is the worst failure an audit tool has. So:
`config.drill_down_slack` defaults to a generous 24 hours (the long tail is a
console session, which holds one id open for as long as the operator stays logged
in); `bounded?` / `scope_description` are rendered on the screen so a narrowed
view cannot pass for a complete one; and `?full=1` drops the bound entirely.
`request_drill_down_spec.rb` asserts both that it prunes *and* that it returns
exactly what the unbounded query returns.

**Seed data has to honour this.** Backdating `occurred_at` without rewriting
`request_id` leaves ids claiming to be minted after the rows they correlate, and
the drill-down then correctly returns nothing. `db/seeds.rb` remaps ids with PG
18's `uuidv7(shift)`, including the `caused_by_request_id` references.

### Stored timestamps are UTC regardless of `config.time_zone`

`config.time_zone` — whether the host app sets it to `UTC`, Eastern, Central, or
anything else — has **no effect** on what the audit tables store. That holds
structurally, not by convention, and `spec/audit_log/utc_storage_spec.rb` exists
to keep it holding. Two properties do all the work:

1. **`occurred_at` is `timestamptz`.** That type stores an absolute instant (8
   bytes, microseconds from 2000-01-01 UTC) and carries **no zone of its own**.
   There is no such thing as a timestamptz "in Eastern"; a zone only ever affects
   how the value is *rendered*. Note the contrast with the demo's business tables,
   which use Rails' default zoneless `timestamp` for `created_at`/`updated_at`.
2. **Nothing supplies `occurred_at` from Ruby.** The trigger's `INSERT` omits the
   column (`db/sql/audit_row_change.sql`) and so does `EventSubscriber#emit`, so
   the column `DEFAULT clock_timestamp()` fills it *inside Postgres*. No Ruby
   zone, no Active Record type cast, and no session `TimeZone` is in the path.

Measured across four app zones, the stored instant tracks wall-clock UTC to
within a millisecond — not shifted by the zone's offset:

| `config.time_zone` | stored `occurred_at` (UTC) | drift vs wall UTC |
|---|---|---|
| `UTC` | `2026-08-27T21:53:42.730Z` | 0.073 s |
| Eastern | `2026-08-27T21:53:42.741Z` | 0.001 s |
| Central | `2026-08-27T21:53:42.744Z` | 0.001 s |
| `Asia/Kolkata` | `2026-08-27T21:53:42.746Z` | 0.001 s |

The two ways to break it, both of which the spec catches:

- **Changing the column to `timestamp without time zone`.** It would then store
  whatever wall-clock string the writer produced, making a row's meaning depend on
  the writer's zone — and two rows written from differently-configured processes
  would be incomparable.
- **Routing the value through Ruby** (`occurred_at: Time.current` in the
  subscriber, or adding the column to the trigger's `INSERT`). A timestamptz
  column still round-trips correctly, so this fails silently rather than loudly;
  it puts Active Record's casting and the host app's zone config into a path that
  currently has neither. The spec asserts against both source files directly.

Related but separate: partition **boundaries** are also UTC, for different
reasons — see below.

### Every partition boundary is UTC midnight

An invariant, not a preference. `occurred_at` is `timestamptz` filled by
`clock_timestamp()` — an absolute instant with no zone of its own — so UTC is the
only boundary that is not an arbitrary choice. More importantly, **UTC has no
DST**: a boundary defined in a DST-observing zone sits 23 or 25 hours from its
neighbour twice a year, so adjacent months either overlap (`CREATE TABLE …
PARTITION OF` fails) or leave a gap — and rows falling in a gap land in the
default partition, which then *blocks* attaching the real one.

Three things enforce it:

1. **`create_month!` pins the offset in the DDL literal** (`'2026-09-01
   00:00:00+00'`). A bare `'2026-09-01'` is resolved against the session
   `TimeZone` **at DDL time**, so the same code run from `psql` (server default
   zone) and from Rails (UTC) produces boundaries hours apart. This was a real
   latent bug, and `partitions_spec.rb` has a regression guard that creates a
   March partition from an `America/Detroit` session.
2. **Month arithmetic uses UTC, not `Date.current`.** `Date.current` follows
   `Time.zone`; in an app configured to a US zone it is hours *behind* UTC, so on
   the last day of a month it names the previous month and `ensure!` /
   `freeze_closed!` drift one partition out of step with the data.
3. **`misaligned_bounds` reports any partition that violates it**, and
   `rake audit_log:partitions` warns on each. This is the forcing function for a
   partition created by hand or by a host app that overrides the connection
   timezone.

`ENV["PGTZ"] ||= "UTC"` is set in the engine so `pg_dump` renders those bounds as
`+00` in `structure.sql`. Without it the dump records correct boundaries as
rotating local offsets (`'2026-07-31 20:00:00-04'`) — unambiguous to Postgres,
since the offset is explicit, but it reads to a reviewer as though the months are
misaligned and it shifts spuriously across DST. It changes no runtime behaviour:
the adapter issues its own `SET time zone 'UTC'` on every connection.

**`AuditLog::DateRange` is the one deliberate exception** and must stay that way.
A UI date filter is a human's calendar day and belongs in `Time.zone`. The cost is
that an app-zone range crosses a UTC month boundary and touches **one extra
partition** — a known `+1`, not a bug, and not worth trading the correct
auditor-facing semantic for. Do not "fix" it by moving the partition boundaries
into the app zone.

### The partition lifecycle

Four operations, and only the first one is safe to schedule.

| | What it does | Lock on the parent | Where it belongs |
|---|---|---|---|
| `ensure!` | Provisions the current month plus `partition_months_ahead` | Catalog-only, nothing to scan | **Daily cron.** A missing future partition is a write-path outage |
| `drain_default!` | Moves stranded rows out of the default partition | `ACCESS EXCLUSIVE` | On demand, when `rake audit_log:partitions` warns |
| `rollup!` | Consolidates a closed year's twelve monthlies into one | `ACCESS EXCLUSIVE` for the swap; a full rewrite before it | Maintenance window |
| `retire!` | Detaches (or drops) partitions past the horizon | `ACCESS EXCLUSIVE`, briefly | Quarterly, deliberately |

All three of the manual ones run under `config.maintenance_lock_timeout` (5s).
Without it, a maintenance statement waiting for `ACCESS EXCLUSIVE` behind one
long-running reader blocks *every* lock request queued behind it — which is to
say the audit write path for the whole application. Failing fast and reporting
is strictly better than a maintenance task that takes production down.

#### The three manual operations cannot overlap

`drain_default!`, `rollup_year!` and `retire!` each take a session-level advisory
lock and refuse immediately if another session holds it. That is not tidiness: it
closes a hole in the rollup's late-write guard. `drain_default!` reinserts
relocated rows under their **original** ids, which are by definition below a
watermark taken later, so a drain that lands a row in a monthly partition midway
through a rollup would slip past `id > watermark` and be dropped along with that
partition. Rollup phase 1 deliberately holds no lock on the parent, so the
interleaving is reachable.

The lock calls run inside `connection.uncached`, and that is load-bearing.
`pg_try_advisory_lock` is a `SELECT` with a side effect, so ActiveRecord's query
cache treats it as an ordinary read — acquire, release, acquire again with no
intervening `execute` and the second acquire is served from cache as `true` while
`pg_locks` shows the session holding nothing. Mutual exclusion that reports
success and does nothing is worse than none.

#### Draining the default partition

A row whose month has no partition lands in `audit_changes_default` — that is
the backstop working. The trap is what happens next: **a partition covering that
range can no longer be created**, because Postgres validates the default
partition's implied constraint and refuses.

```
ERROR:  updated partition constraint for default partition "audit_changes_default"
        would be violated by some row
```

So the rows have to come *out* before the partition can go *in*. `drain_default!`
does that in one transaction: stage the rows into a temp table, create the real
partitions, insert them back so routing files them correctly. A failure anywhere
leaves them in the default partition — exactly where they started, still
queryable through the parent, nothing lost. Ids are preserved.

The month a row is filed under is computed as
`date_trunc('month', occurred_at AT TIME ZONE 'UTC')`. Applying `date_trunc`
directly to a `timestamptz` truncates in the *session* zone, which for a row near
a month boundary picks the wrong partition and fails the insert.

#### Rolling months up into years

A 7-year horizon at monthly granularity is 84 partitions per table, 168 in total
— every one a relation the planner considers, autovacuum tracks, and `pg_dump`
walks. `rollup!` consolidates any calendar year older than
`config.rollup_after` (2 years) into a single yearly partition, taking that to
roughly five yearly partitions plus a rolling window of months.

**PostgreSQL has no `ALTER TABLE ... MERGE PARTITIONS`.** The patch was reverted
before 17 shipped and is absent from 18, so this is a hand-rolled copy-and-swap,
staged so the exclusive lock covers catalog work only:

1. Build a standalone table with `LIKE parent INCLUDING ALL` and fill it from the
   year's partitions. The parent is untouched; the application keeps writing.
   `INCLUDING ALL` carries the indexes, which is what lets `ATTACH` match them
   against the parent's partitioned indexes instead of rebuilding them under the
   lock. A validated `CHECK` matching the future bound lets `ATTACH` skip its own
   validation scan — same work, paid outside the lock.
2. In one short transaction: detach the twelve monthlies, `ATTACH` the new table,
   drop the now-redundant `CHECK`, drop the monthlies.

Correctness rests on the year being closed, and that assumption is **asserted,
not trusted**: an id watermark taken *before* the copy is re-checked after the
detach, and a single row that arrived in between rolls the whole swap back. The
watermark is taken before rather than after the copy on purpose — one read after
the copy would not catch a row that landed *during* it, which is precisely the
row that would be lost.

`ATTACH` also has to scan the default partition to prove no row there belongs in
the incoming range, so `rollup_year!` checks that first and points at
`drain_default!` rather than failing cryptically at the end of a long copy.

If a rollup dies after the copy but before the swap, its staging table survives
under the target name, holding a full year of audit data. It carries a table
comment marking it as this library's debris, which is the only thing separating
"safe to recreate" from "somebody else's table, and dropping it destroys data" —
so `rollup_year!` refuses an unmarked table rather than reaching for
`DROP TABLE IF EXISTS`. `orphaned_rollups` reports marked debris, and
`rake audit_log:partitions` warns about it with its size; a re-run reclaims it.

Two costs worth stating. It rewrites a full year of data. And it coarsens
retention: a yearly partition can only be retired whole, so up to eleven extra
months are kept past the horizon. Both are fine for cold years and neither is
for warm ones — which is what `rollup_after` is for.

#### Retention

`config.retention` defaults to **7 years**; `nil` disables retirement entirely.
A partition expires when its **upper** bound is older than the horizon, never its
lower — keying on the lower bound would retire a month that still holds days
inside it.

`config.retention_action` defaults to `:detach`, not `:drop`, and that asymmetry
is deliberate. Detaching is reversible with a single `ATTACH`, so a wrong horizon
costs an afternoon; dropping is not, and an audit log is the worst table in the
database to discover a wrong setting in. Detached partitions keep their rows and
their disk under a `_retired_` name, and `rake audit_log:partitions` reports them
with their size so they cannot pile up unseen. Switch to `:drop` once something
exports them first.

The rename is not cosmetic: it makes "expired, awaiting export" a visible state,
and it stops `create_month!` from mistaking a retired table for a live partition.

```bash
DRY_RUN=1 bin/rails audit_log:retention   # what would go, and when
DRY_RUN=1 bin/rails audit_log:rollup      # which years would consolidate
```

#### Why not pg_partman?

It would replace roughly 65 of `partitions.rb`'s 103 code lines — about 2.5% of
the library — and it would not replace the parts that matter. Scheduling does not
go away (`run_maintenance_proc` still needs pg_cron, a background worker
requiring `shared_preload_libraries`, or a rake task, and the failure mode is
identical). The UTC-boundary hazard does not go away either — partman derives
bounds with `date_trunc` against the maintenance session's `TimeZone`, which is
exactly the bug fixed in `create_month!`, except no longer ours to fix. And it
breaks plan §2.4's "no extensions", which is what makes this installable from an
ordinary migration with no superuser.

What partman is genuinely better at is retention and relocating rows out of the
default partition. Both are now implemented above.

### Application code addresses the parent table, never a partition

`audit_changes` and `audit_events` are partitioned parents with no storage of
their own. Every query object, model, and raw SQL statement in application code
reads and writes the **parent**; Postgres routes inserts and prunes reads. Naming
a partition directly is reserved for operations that are inherently
per-partition, all of which live in `partitions.rb` or the rake tasks:
`VACUUM (FREEZE, ANALYZE)` on a closed month, `SELECT count(*)` on the default
partition, and `DETACH`/`DROP` for retention.

Note that Postgres creates **nothing** automatically — declarative partitioning
gives you routing and pruning, never provisioning. That is the entire reason
`Partitions.ensure!` and its daily recurring task exist, and the reason
`pg_partman` exists at all — see [Why not pg_partman?](#why-not-pg_partman)
above for why this library does not use it.

## Not implemented (deliberately)

Per [`AUDIT_LOGGING_PLAN.md`](../../AUDIT_LOGGING_PLAN.md) §12, §13, §15:

- **Database-level append-only enforcement.** `REVOKE UPDATE, DELETE` plus a
  rejecting trigger. Additive, needs no schema change — but it requires
  `SECURITY DEFINER` and an owner role, which is the one thing that complicates
  managed-Postgres deployment.
- **Cryptographic tamper evidence.** If ever needed, do it as a nightly sealing
  job, never in the trigger: an in-trigger `prev_hash` chain serializes every
  write through one hot tuple.
- **Export of retired partitions.** `retire!` detaches and reports; what happens
  to a detached partition — `COPY` to object storage, `pg_dump -t`, a cold
  tablespace — is a deployment decision, not a library one. Until one is made,
  `retention_action` stays `:detach` and the partitions sit in the schema where
  `rake audit_log:partitions` keeps naming them.
- **PII redaction.** Blocked on a policy decision.
- **Read-access logging.** Explicitly out of scope.
