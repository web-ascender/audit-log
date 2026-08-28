# AuditLog — Design Record

**Status:** validated against the working implementation in this gem, and against
the reference application in `../audit-log-demo`
**Last updated:** 2026-08-28

> **Why this decision is what it is.** This is the reasoning behind every choice in this gem, and
> it travelled with the code when the library was extracted from the reference app — which was the
> point of writing it here rather than in a wiki. [`README.md`](README.md) is the install-and-use
> guide; this file is the *why*, and it is the single source of truth for it — where the README or
> `CLAUDE.md` state a decision, they state it briefly and link here.
>
> Section numbers are cited from source comments (`plan §6.1`, `§11.0 Rule 1`, and a dozen more),
> so **they are stable**. Sections 15, 18 and 19 covered project rollout; that is not library
> documentation and lives in the reference app's `ROLLOUT.md`. Nothing renumbered. As of
> 2026-08-28 no open question remains: the last four closed as retention (§8), export (§8),
> redaction (§13) and pagination (§11.0) were built. Section 19 planned improvements to the existing
> paper_trail applications and was dropped on 2026-08-28 — this library is for new projects, and
> those apps are not being migrated.
>
> Sections corrected by actually building the thing are marked **[corrected 2026-08-27]**. Those
> are the most valuable paragraphs here: every one was a defect that failed *silently*.
---

## 1. Goal

Maintain a compliance-grade audit / activity log that can answer both of these questions
cheaply, at hundreds of thousands of rows and beyond:

1. **Forensic:** "Every field-level change ever made to `Order#4821`, with old and new values."
2. **Narrative:** "Everything Jane did on Tuesday, and for each action, every record it touched."

Question 2 is the one `paper_trail` cannot answer without pain, and it is the one auditors
actually ask. A single Rails form submit that saves a parent plus forty `accepts_nested_attributes_for`
children must read as **one action**, not forty unrelated version rows.

### Requirements

| # | Requirement |
|---|---|
| R1 | Per-field before/after values for create, update, destroy |
| R2 | Complete — no write path may silently bypass the log |
| R3 | Atomic with the change it describes (commits together, rolls back together) |
| R4 | Groups all records touched by one user action into one readable event |
| R5 | Human-readable enough to render directly to a non-technical auditor |
| R6 | Historically stable — display must not change when referenced records are renamed or deleted |
| R7 | Append-only; tamper-resistant |
| R8 | Queryable and prunable at scale (partitioning, retention) |

### Explicit non-goals

- **No `reify` / rollback.** We have never used paper_trail's object restoration and will not
  store full row snapshots. This is the single biggest bloat saving available to us.
- **No analytics.** Page views, funnels, and product telemetry do not belong in the audit
  tables. They ride the same emission API (§7) to a different subscriber.

---

## 2. Platform requirements

| Component | Hard floor | Supported floor | Recommended | Gated on |
|---|---|---|---|---|
| **Ruby** | 3.3 | 3.4 | 3.4.5+ | `SecureRandom.uuid_v7` |
| **Rails** | 8.0 | 8.1 | 8.1.3+ | `Rails.event` structured events |
| **PostgreSQL** | 13 | 16 | 18 | row triggers on partitioned parents |
| **Solid Queue** | 1.0 | 1.x | latest | ActiveJob-only queue backend |
| **Pagy** | 9.0 | 9.x | latest | `Pagy::Keyset` |

"Hard floor" is where the design stops working. "Supported floor" is what we will actually test
and run against. Our existing apps are on Ruby 3.4.5, Rails 8.1.3, and PostgreSQL 16+, so nothing
here asks for an upgrade.

### 2.1 Ruby

**3.3 is the hard floor**, entirely for `SecureRandom.uuid_v7` (§20.1). UUIDv7 correlation ids are
what give the `audit_changes (request_id)` index insert locality on the highest-volume table in
the database; UUIDv4 scatters page splits across the whole index.

*Below 3.3:* generate v7 by hand (a 48-bit big-endian millisecond timestamp, version and variant
nibbles, the rest random) or take a small gem. Falling back to `SecureRandom.uuid` costs write
throughput and index bloat but breaks nothing functionally.

### 2.2 Rails

**8.1 is the supported floor**, for `Rails.event` / `ActiveSupport::EventReporter` — the structured
event API that layer 2 is built on (§7). Everything else the plan uses is older:
`ActiveSupport::CurrentAttributes#set`, `ActiveSupport.on_load(:active_record_postgresqladapter)`,
`insert_all` / `upsert_all`, and `schema_format = :sql` are all long-established.

*On 8.0:* the design works unchanged if `Rails.event.notify(name, **payload)` is replaced with a
direct `Audit.record(name, **payload)` call that writes `audit_events`. What is lost is the
fan-out — the ability to register a second subscriber shipping the same event to observability
without touching domain code. That is a real convenience, not a load-bearing dependency, so **8.0
is the hard floor**.

Also required, and available in the 8.x line: `config.active_job.enqueue_after_transaction_commit`,
which keeps a rolled-back transaction from leaving an enqueued job behind (§6.4). Confirm the
setting is honored by the adapter in use before relying on it.

**There is also a ceiling: `~> 8.0`, i.e. below 9.0.**  **[added 2026-08-28]** Not a formality.
`TransactionStamp` prepends `raw_execute`, which is a *private* adapter method — §6.1 calls it the
single private choke point every write funnels through — and a major version is free to move
exactly that. An unbounded `>= 8.0` asserted that Rails 9 and 10 work, which nobody has verified.
Raising the ceiling means re-verifying the prepend against the new adapter internals first, and the
guard for that is `completeness_spec`: if `raw_execute` stops being the choke point, `update_all`
and raw SQL start landing with a NULL actor and nothing else reports it.

### 2.3 PostgreSQL

**13 is the hard floor.** The binding constraint is `AFTER ... FOR EACH ROW` triggers on a
*partitioned parent* propagating to its partitions. Everything else — `jsonb`, `jsonb_object_keys`,
GIN on `text[]`, `set_config(..., true)`, declarative range partitioning — predates it comfortably.

**16 is the supported floor**, because it is what our apps already target and because PG 13–15 are
either EOL or close to it. PG 17 is worth taking if convenient: its rewritten vacuum memory
management materially speeds up vacuum on very large tables, which is exactly what
`audit_changes` becomes.

**18 is recommended but explicitly non-blocking.** §20 covers what it adds; the headline is eager
page freezing, which suits insert-only partitions better than anything else in the release, and
which matters more the longer the retention horizon is — seven years, per
the reference app's `ROLLOUT.md` Q2.

*Below 13:* attach the trigger to each partition individually instead of the parent, and add it to
the partition-creation job. Workable, one more moving part. Below 11, abandon partitioning.

### 2.4 What is *not* required

- **No PostgreSQL extensions.** No `pgcrypto`, no `hstore`, no `pgaudit`, no `timescaledb`.
  `pg_partman` was evaluated for partition rotation and rejected — see §8 for the measurement; a
  scheduled job replaces it, and retention and rollup are implemented directly.
- **No superuser.** The trigger function runs with the caller's privileges (§12), so the whole
  design installs from an ordinary migration on managed Postgres — RDS, Aurora, Cloud SQL, Fly,
  Heroku. This is deliberate: reintroducing `SECURITY DEFINER` for append-only enforcement would
  require an owner role with rights the app role lacks, which is the one change that would
  complicate managed-database deployment.
- **No gems for the audit machinery.** Layers 1 and 2 are application code plus DDL. The `fx` gem
  (versioned function and trigger files, dumped into `schema.rb`) was evaluated and dropped:
  partitioned tables force `structure.sql` regardless (§4), and `pg_dump` already captures functions
  and triggers, so `fx` would add a dependency for nothing.

  The **auditor UI** does take two, and they are worth naming precisely because the sentence above
  is easy to over-read: `pagy` for keyset pagination (§11.0) and `csv` for export (§11.4a) — the
  latter because `csv` stopped being a Ruby default gem in 3.4, so `require "csv"` alone is a
  `LoadError`. Neither is referenced by the trigger, the correlation context, or the event
  subscriber; an adopter who takes only layers 1 and 2 needs neither. [revised 2026-08-28]
- **No queue backend commitment.** Solid Queue is the target, but §6.4's ActiveJob concern is
  adapter-independent; the Sidekiq middleware in §6.4 exists only for non-ActiveJob workers.

---

## 3. Architecture: two layers, one correlation id

```
                 ┌──────────────────────────────────────────────┐
  HTTP request   │  Current.request_id = <uuid>                  │
  or ActiveJob   │  Current.actor      = User#17                 │
                 └──────────────────┬───────────────────────────┘
                                    │
              ┌─────────────────────┴─────────────────────┐
              │  (also: rake, console, migrations → §6.5)  │
              └─────────────────────┬─────────────────────┘
              ┌─────────────────────┴─────────────────────┐
              │                                           │
   ┌──────────▼───────────┐                    ┌──────────▼──────────┐
   │  LAYER 2 (app)       │                    │  LAYER 1 (Postgres) │
   │  Rails.event.notify  │                    │  AFTER ROW triggers │
   │  "order.submitted"   │                    │  on every audited   │
   │          │           │                    │  table              │
   │          ▼           │                    │         │           │
   │   audit_events       │                    │         ▼           │
   │   1 row per ACTION   │◄────request_id────►│   audit_changes     │
   │   who / what / why   │                    │   1 row per ROW     │
   │   human summary      │                    │   jsonb field diff  │
   └──────────────────────┘                    └─────────────────────┘
```

**Layer 1 — change capture.** Postgres `AFTER INSERT OR UPDATE OR DELETE ... FOR EACH ROW`
triggers write a compact jsonb delta to a partitioned, append-only table. Because it lives in
the database, *nothing* bypasses it: not `update_all`, not `delete_all`, not `upsert_all`, not
`dependent: :delete_all`, not a `dependent: :destroy` cascade, not raw SQL, not a rake task, not
a console session. This satisfies R1, R2, R3.

**Layer 2 — activity narrative.** The application emits a named domain event per meaningful user
action. One durable subscriber writes a row to `audit_events` carrying the actor, a denormalized
actor label, the subject, and a rendered human sentence. This satisfies R5, R6.

**The join is `request_id`.** Set once per request into a Postgres transaction-local setting, read
by the trigger, stamped onto every row change. One form submit → one `audit_events` row → N
`audit_changes` rows sharing a uuid. That satisfies R4, and it is the entire reason this design
beats bolting more columns onto paper_trail.

### Options considered and rejected

| Option | Verdict |
|---|---|
| **paper_trail** (current, 12 apps) | Perf and query issues are fixable (drop `object`, GIN index `object_changes`, add `transaction_id`, partition). The unfixable problem is completeness: it is AR-callback-based, so `update_all` / `delete_all` / `insert_all` / DB cascades / raw SQL are silently missed. "Complete except when a developer used `update_all`" is not defensible under audit, and the gap is invisible. Not carried into the new project. |
| **audited** | Same callback architecture, same completeness gap. Its one nice feature — `associated_with:` rolling child audits under a parent — we get for free from `request_id`. |
| **logidze** | Excellent at record-local history with no joins, wrong shape for us. Its README is explicit: *"Logidze is designed to only track changes. If the record has been deleted, everything is lost."* History lives in a `log_data` jsonb column on the row itself, so no cross-table or by-user query is possible without scanning every table; `--limit=N` compaction is deliberately lossy; hot rows bloat and TOAST. |
| **Rails 8.1 structured events alone** | An emission/fan-out API, not storage. No durability or transactional guarantee, no AR hooks. Used as layer 2's front door (§7), never as the log itself. |
| **pgaudit** | Session/DDL-level audit for DBA activity. Complementary if a regime demands it; does not replace application-level audit. |
| **Debezium / logical replication** | Correct at a scale we are not at, and adds an operational dependency. Revisit only if audit write volume becomes a measurable share of DB load. |

---

## 4. Schema

`db/structure.sql` is **required** — `schema.rb` cannot represent partitioned tables or triggers.
Set `config.active_record.schema_format = :sql` on day one, before any migrations exist.

```sql
-- ============================================================
-- LAYER 2: what an auditor reads. One row per business action.
-- ============================================================
CREATE TABLE audit_events (
  id            bigserial,
  occurred_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  request_id    uuid        NOT NULL,              -- UUIDv7, app-generated (§20.1)
  action        text        NOT NULL,              -- "order.submitted"
  actor_type    text,                              -- User | ApiKey | System
  actor_id      bigint,
  actor_label   text,                              -- "Jane Smith <jane@x.com>"  SNAPSHOT
  subject_type  text,
  subject_id    bigint,                            -- the aggregate root
  source        text        NOT NULL,              -- web | api | job | console | system
  ip            inet,
  user_agent    text,
  summary       text        NOT NULL,              -- rendered human sentence  SNAPSHOT
  metadata      jsonb       NOT NULL DEFAULT '{}',
  PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

CREATE INDEX ON audit_events (occurred_at DESC);
CREATE INDEX ON audit_events (actor_type, actor_id, occurred_at DESC);      -- Q1
CREATE INDEX ON audit_events (action, occurred_at DESC);                    -- Q3
CREATE INDEX ON audit_events (subject_type, subject_id, occurred_at DESC);
CREATE INDEX ON audit_events (request_id);

-- ============================================================
-- LAYER 1: forensic detail. One row per row-level change.
-- Written ONLY by the trigger function.
-- ============================================================
CREATE TABLE audit_changes (
  id              bigserial,
  occurred_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
  request_id      uuid,                            -- NULL = out-of-band write (see §9)
  record_type     text   NOT NULL,                 -- "Order"  (model name, not table name)
  record_id       bigint NOT NULL,
  operation       char(1) NOT NULL,                -- I | U | D
  diff            jsonb  NOT NULL,                 -- {"status": ["pending","approved"]}
  changed_columns text[] NOT NULL,                 -- {status}  -- denormalized keys of diff
  actor_type      text,                            -- User | ApiKey | System
  actor_id        bigint,
  actor_label     text,                            -- "Jane Smith <jane@x.com>"  SNAPSHOT
  PRIMARY KEY (id, occurred_at),
  CONSTRAINT audit_changes_operation_check CHECK (operation IN ('I','U','D'))
) PARTITION BY RANGE (occurred_at);

CREATE INDEX ON audit_changes (actor_type, actor_id, occurred_at DESC);     -- Q1 detail
CREATE INDEX ON audit_changes (record_type, record_id, occurred_at DESC);   -- Q2 single record
CREATE INDEX ON audit_changes (record_type, occurred_at DESC);              -- Q2 whole class
CREATE INDEX ON audit_changes (request_id);                                 -- drill-down
CREATE INDEX ON audit_changes USING gin (changed_columns);                  -- "which field?"
CREATE INDEX ON audit_changes (occurred_at DESC);

```

### Schema decisions worth defending

- **The column is `diff`, not `changes`.** An AR model with a `changes` column would override
  `ActiveModel::Dirty#changes`, which breaks in confusing ways. Do not rename it back.
- **jsonb delta per row-change, not one row per column.** Value arrays are `[old, new]`; `null` on
  the old side means insert, on the new side means delete. We avoid multiplying row count by
  column count.
- **`changed_columns text[]` is denormalized from `diff`'s keys**, and it is the *only* GIN index
  on the table. Reason: a `jsonb_path_ops` GIN index does **not** support the `?` key-existence
  operator — only `@>`, `@?`, `@@`. Answering "which changes touched `status`" against
  `jsonb_path_ops` silently falls back to a sequential scan. The default `jsonb_ops` opclass does
  support `?`, but it indexes every key *and* every value, making it far larger than we need. A
  GIN index on a `text[]` of just the column names is smaller, directly answers the question
  (`changed_columns && ARRAY['status']`), and lets the UI list the changed fields without
  deserializing `diff` at all. Value-level search ("find where status *became* 'void'") is a rare,
  expensive need — add a `jsonb_path_ops` index for `@>` containment later if it materializes.
- **`actor_type` is carried on `audit_changes`, not just `audit_events`.** Without it, `actor_id`
  collides across `User#17` and `ApiKey#17`, and the actor index is unusable for Q1.
- **`actor_label` is denormalized onto `audit_changes` too**, rather than resolved through a
  lookup table. Considered and rejected: an `audit_actors` dimension joined at read time. Three
  reasons the denormalization wins. (1) *Consistency of principle* — a dimension table holds the
  actor's **current** label, so renaming a user retroactively rewrites what old change rows appear
  to say. That is the exact failure R6 exists to prevent, and we would have been applying the
  snapshot rule on `audit_events` while breaking it one table over. (2) *Coverage* — any
  dimension maintained from the event subscriber only ever learns about actors from **registered**
  actions, so change rows on unregistered or out-of-band paths (§9, §11.5) would resolve to no
  label at all. Those are precisely the rows an auditor scrutinizes most. Maintaining it correctly
  means a second write path firing on every request, which is more machinery than the column it
  replaces. (3) *Storage is not the constraint it looked like* — a `diff` averages a few hundred
  bytes and can reach kilobytes, so a ~40-byte label is single-digit percentage growth on a table
  whose whole purpose is storing per-row detail. Cap the label at 255 chars to keep that bounded.
- **`clock_timestamp()`, not `now()`.** `now()` is fixed at transaction start, so every change in
  one transaction would share a timestamp and lose intra-transaction ordering. `clock_timestamp()`
  advances. (`id` from the shared sequence is the tiebreaker.)
- **Composite PK `(id, occurred_at)`.** Postgres requires the partition key in the primary key.
  The Rails models set `self.primary_key = :id` and are read-only, so this never surfaces.
- **`actor_label` and `summary` are snapshots, not joins.** If the auditor UI joins live to
  `users` to render a name, then renaming or deleting a user retroactively changes what the audit
  record *says happened*. Auditors read that as tampering. We denormalize deliberately (R6).
  Same rule applies to any foreign key we display: snapshot the label into `metadata`.
- **`request_id` is nullable on `audit_changes` and NOT NULL on `audit_events`.** A change with no
  request_id is a write that happened outside a correlated request — a console session, a
  migration, a data fix. That is exactly what an auditor most wants flagged, so we keep it as a
  first-class signal rather than fabricating an id (§9).

---

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

---

## 5. The trigger function

One function, defined once, parameterized per table. It runs with the caller's privileges (see
§12 — we are not enforcing append-only grants), but still pins `search_path` so the function
cannot be hijacked by a schema-shadowed object.

```sql
CREATE OR REPLACE FUNCTION public.audit_row_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  excluded text[] := string_to_array(coalesce(TG_ARGV[0], ''), ',');
  model    text   := TG_ARGV[1];
  delta    jsonb;
  rec_id   bigint;
  rid      uuid;
  atype    text;
  aid      bigint;
  alabel   text;
BEGIN
  -- Explicit, logged bypass for bulk loads. See §10.
  IF coalesce(current_setting('app.audit_bypass', true), 'off') = 'on' THEN
    RETURN NULL;
  END IF;

  rid   := nullif(current_setting('app.request_id', true), '')::uuid;
  atype := nullif(current_setting('app.actor_type',  true), '');
  aid   := nullif(current_setting('app.actor_id',    true), '')::bigint;
  alabel:= left(nullif(current_setting('app.actor_label', true), ''), 255);

  IF TG_OP = 'UPDATE' THEN
    SELECT jsonb_object_agg(n.key, jsonb_build_array(o.value, n.value))
      INTO delta
      FROM jsonb_each(to_jsonb(OLD)) o
      JOIN jsonb_each(to_jsonb(NEW)) n USING (key)
     WHERE o.value IS DISTINCT FROM n.value
       AND NOT (n.key = ANY (excluded));
    IF delta IS NULL THEN RETURN NULL; END IF;   -- no-op update, write nothing
    rec_id := NEW.id;

  ELSIF TG_OP = 'INSERT' THEN
    SELECT jsonb_object_agg(key, jsonb_build_array(NULL, value))
      INTO delta
      FROM jsonb_each(to_jsonb(NEW))
     WHERE NOT (key = ANY (excluded));
    rec_id := NEW.id;

  ELSE  -- DELETE
    SELECT jsonb_object_agg(key, jsonb_build_array(value, NULL))
      INTO delta
      FROM jsonb_each(to_jsonb(OLD))
     WHERE NOT (key = ANY (excluded));
    rec_id := OLD.id;
  END IF;

  delta := coalesce(delta, '{}'::jsonb);

  INSERT INTO audit_changes
    (request_id, record_type, record_id, operation, diff, changed_columns,
     actor_type, actor_id, actor_label)
  VALUES
    (rid, model, rec_id, left(TG_OP, 1), delta,
     ARRAY(SELECT jsonb_object_keys(delta)), atype, aid, alabel);

  RETURN NULL;   -- AFTER trigger; return value is ignored
END;
$$;
```

### 5.1 Attaching it

A migration helper keeps this uniform:

```ruby
# db/migrate/.../_helpers, or lib/audit/migration_helpers.rb
module Audit::MigrationHelpers
  DEFAULT_EXCLUDED = %w[
    created_at updated_at lock_version
    password_digest remember_created_at reset_password_token
  ].freeze

  def attach_audit_trigger(table, model:, exclude: [])
    cols = (DEFAULT_EXCLUDED + exclude.map(&:to_s)).uniq.join(",")
    execute <<~SQL
      CREATE TRIGGER #{table}_audit
      AFTER INSERT OR UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('#{cols}', '#{model}');
    SQL
  end

  def detach_audit_trigger(table)
    execute "DROP TRIGGER IF EXISTS #{table}_audit ON #{table};"
  end
end
```

**Exclusion policy.** Always exclude `updated_at` (noise on every row) and `lock_version`. Exclude
`*_ciphertext` / `encrypted_*` columns — logging ciphertext deltas is useless and doubles storage.
Exclude large `text`/`bytea` columns unless the requirement specifically covers them; if it does,
store a digest rather than the body. Every exclusion is a deliberate, reviewable decision recorded
in the migration.

**`TRUNCATE` bypasses row-level triggers entirely.** Revoke `TRUNCATE` from the application role,
and if any operational path needs it, add a statement-level trigger that writes a marker row.
---

### 5.2 What does a new model need? Nothing in the class.

**Layer 1 is entirely out-of-band.** There is no `has_paper_trail`, no `include Auditable`, no
callback, no concern. An audited model is an ordinary `ApplicationRecord` subclass. The tracking
lives in the database, which is exactly why `update_all` and raw SQL cannot escape it.

**But it is not automatic either.** A new table gets audited when — and only when — a migration
attaches the trigger:

```ruby
class CreateOrders < ActiveRecord::Migration[8.1]
  include Audit::MigrationHelpers

  def change
    create_table :orders do |t|
      # ...
    end
    attach_audit_trigger :orders, model: "Order"
  end
end
```

That is the whole per-model cost: one line, in the migration, next to the table it audits.

**Next to the `create_table` is a review convention, not a requirement.**  **[clarified 2026-08-28]**
The helper is a bare `CREATE TRIGGER`; it reads nothing from the `create_table` beside it, and the
coverage check queries `pg_trigger` rather than the migration history. So an existing table is
attached from a standalone migration just as well, and `rails generate audit_log:trigger orders`
writes one. What such a table does *not* get is history for changes that already happened — the
first `UPDATE` after attaching yields a complete `[old, new]` pair, and nothing before it exists.
Record the attach date; the migration's own timestamp is the durable answer.

Changing a table's exclusions or model name is **detach-then-attach**
(`audit_log:trigger … --replace`), because `attach_audit_trigger` is deliberately *not* idempotent:
the trigger name derives from the table alone, so a second attach collides with `42710` instead of
letting two triggers coexist on one table and write two rows per change under different exclusion
sets. It is not retroactive — rows already written keep the diffs they were written with.

**The real constraint is the table's shape, and it fails late.** The trigger function assigns
`rec_id bigint := NEW.id`, and `audit_changes.record_id` is `bigint NOT NULL`. An `id: false` join
table, a `uuid` primary key, or a primary key not named `id` therefore fails on the **first write
after attaching**, not at migration time. §5.3 covers the tables the trigger cannot handle as
written. The generator warns about this and cannot check it: it has no connection to the table.

Automatic-by-default was considered and rejected. Auditing *every* table would sweep in
`solid_cache_entries`, `solid_queue_jobs`, `sessions`, and every join table — high-churn tables
with no compliance value that would dominate the audit volume and bury real findings. The
attach decision should be explicit and reviewable in the migration diff.

**The forcing function is the coverage spec**, so "explicit" never degrades into "forgotten":

```ruby
# spec/audit/coverage_spec.rb
UNAUDITED = {
  "schema_migrations"    => "Rails internal",
  "ar_internal_metadata" => "Rails internal",
  "audit_events"         => "the audit log itself",
  "audit_changes"        => "the audit log itself",
  "sessions"             => "high churn, no compliance value",
  # Under Solid Queue, add every solid_queue_* table here -- see §6.4.
}.freeze

it "audits every table that has not been explicitly excluded" do
  # ApplicationRecord, not ActiveRecord::Base: with a separate queue/cache database
  # we only want the primary connection's tables.
  #
  # Partitions must be subtracted too. [corrected 2026-08-27] `conn.tables` lists every
  # monthly partition of audit_changes/audit_events, and a partition inherits its
  # parent's triggers and cannot be attached independently -- so it is not a
  # candidate for auditing. Subtracting them here, rather than listing each one in
  # UNAUDITED, keeps the exemption list about DECISIONS instead of about partition
  # rotation (which would otherwise need a new entry every month, forever).
  conn       = ApplicationRecord.connection
  partitions = conn.select_values(
    "SELECT c.relname FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid"
  )
  tables  = conn.tables - UNAUDITED.keys - partitions
  audited = conn.select_values(<<~SQL)
    SELECT c.relname FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    WHERE NOT t.tgisinternal AND t.tgname LIKE '%_audit'
  SQL
  expect(tables - audited).to be_empty,
    "Untracked tables: #{(tables - audited).join(', ')}. " \
    "Add attach_audit_trigger, or add to UNAUDITED with a reason."
end
```

Adding a table without deciding about auditing now breaks the build, and every exemption carries a
written reason in one reviewable file. This spec is the single most valuable test in §16.

**Layer 2 does require code**, because no database can infer that saving six rows constituted
"submitting an order." A model or service emits the domain event, and the action gets a registry
entry (§7):

```ruby
# app/models/order.rb
def submit!
  transaction do
    update!(status: :submitted, submitted_at: Time.current)
    line_items.each(&:lock_pricing!)
    Rails.event.notify("order.submitted", order_id: id, total_cents: total_cents,
                                          line_count: line_items.size)
  end
end
```

So: **field-level tracking is free per model; the human narrative is opt-in per action.** A model
with no `notify` call is still fully audited at the record level — its changes simply appear under
the generic view rather than a named action, which §11.5 surfaces so the registry keeps filling in.

### 5.3 Tables the trigger cannot handle as written

The function dereferences `NEW.id` / `OLD.id` and stores it in a `bigint`. That covers the Rails
default and every table in our existing apps, but four cases need attention:

| Case | Symptom | Handling |
|---|---|---|
| **Table with no `id`** — a `create_join_table` HABTM table | `record "new" has no field "id"` at runtime, on the first write | Do not attach. If the association needs auditing, promote it to `has_many :through` with a real model and PK — a bare join row's diff is meaningless without one anyway. |
| **UUID primary keys** | `invalid input syntax for type bigint` | Change `rec_id` to `text` and `audit_changes.record_id` to `text`, casting `NEW.id::text`. Decide this **before** the first migration; converting later means rewriting every partition. |
| **Composite primary keys** | `NEW.id` missing | Same `text` treatment, storing a delimited key. Rare; prefer a surrogate `id`. |
| **Partitioned business tables** | — | Fine. `AFTER ... FOR EACH ROW` triggers on a partitioned parent are supported on PG 13+ and propagate to partitions automatically; attach to the parent only. |

If the new app will use UUID primary keys anywhere, make that call in Phase 1 — it is the one
schema decision here that is expensive to reverse.

---

## 6. Correlation: request, job, and console context

Everything that makes the two layers join — and that turns a 40-row form submit into one readable
action — comes from three settings reaching the trigger. This section specifies how they get there
from each of the four entry points: web, background job, console, and migration.

### 6.1 The mechanism  **[corrected 2026-08-27]**

> ⚠️ **The transaction-start hook this section originally specified is incomplete, and incomplete
> in exactly the place this design claims to be strong.** `update_all`, `delete_all`, `insert_all`,
> `upsert_all` and `execute` issue a bare statement with **no surrounding transaction**, so
> `begin_db_transaction` never fires and the trigger sees no settings. Those writes are still
> captured — the trigger cannot be bypassed — but they land with a **NULL actor and NULL
> request_id**, indistinguishable from a console session. A design whose headline claim is
> "`update_all` cannot escape the audit log" cannot then fail to say *who ran it*.
>
> This was caught on the first seed run of the reference implementation: five `Product` rows
> updated by `update_all` inside a correlated block, all with `actor_label IS NULL`.
>
> **The fix is to stamp at the statement level instead**, on `raw_execute` — the single private
> choke point that `execute`, `internal_exec_query`, `exec_insert`, `exec_update` and `exec_delete`
> all funnel through. With a per-connection memo the round trip fires only when the stamp is stale,
> which is **once per request rather than once per transaction** — fewer round trips than the
> original design, not more. The cost is one Ruby-level comparison per statement.
>
> Two consequences follow, and both are load-bearing:
>
> 1. **The setting must be session-level (`set_config(..., false)`), not transaction-local.** A
>    transaction-local setting is invisible to a bare `update_all`, which never opens one.
> 2. **The memo must be cleared on rollback.** A session-level `SET` issued inside a transaction is
>    reverted by `ROLLBACK` (and by `ROLLBACK TO SAVEPOINT`), so the connection would otherwise
>    believe a stamp is in force that the server has discarded. The resulting misattribution is
>    silent and points at *whoever acted before the rollback* — so prepend
>    `exec_rollback_db_transaction` and `exec_rollback_to_savepoint` and forget the memo there.
>    An earlier attempt to avoid this by simply *not* memoizing while a transaction was open was
>    worse: the memo then went stale in the "unstamped" direction, so a later reset to the empty
>    stamp matched the stale memo, short-circuited, and left the previous actor's identity in force.
>    A spec caught that one.
>
> Also prepend `configure_connection` — it must both reset the memo (a reconnect discards session
> settings) and *suppress* stamping while it runs, since it issues statements of its own against a
> connection whose type map is not yet built.
>
> See `lib/audit_log/transaction_stamp.rb` and `lib/audit_log/context.rb`.

The reasoning that led to the original transaction-start hook is still worth recording, because it
is most of the way right. `SET LOCAL` is transaction-scoped and auto-clears at commit or rollback,
which gives free isolation between requests sharing a pooled connection. But it is a no-op outside
a transaction, and that turned out to be disqualifying rather than a corner case.

```ruby
# config/initializers/audit_correlation.rb
module Audit
  module TransactionStamp
    def begin_db_transaction
      super
      Audit::Context.apply!(self)
    end
  end

  module Context
    # Only databases that actually hold audited tables. Prevents a wasted round trip
    # on every Solid Queue / Solid Cache transaction -- see §6.4.
    STAMPED_DATABASES = %w[primary].freeze

    def self.apply!(conn)
      return if Current.request_id.blank?   # console / migration: leave NULL, see §9
      return unless STAMPED_DATABASES.include?(conn.pool&.db_config&.name)
      conn.exec_query(
        "SELECT set_config('app.request_id',  $1, true), " \
        "       set_config('app.actor_type',  $2, true), " \
        "       set_config('app.actor_id',    $3, true), " \
        "       set_config('app.actor_label', $4, true)",
        "AUDIT CONTEXT",
        [Current.request_id.to_s, Current.actor_type.to_s,
         Current.actor_id.to_s,   Current.actor_label.to_s]
      )
    end
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend Audit::TransactionStamp
end
```

Notes:

- One statement, four settings, **one round trip per real transaction**. `SET LOCAL` accepts only
  a single parameter per statement, so `set_config(..., true)` is used instead — `true` means
  local. Adding settings costs nothing extra; it is the round trip that matters.
- Savepoints do not call `begin_db_transaction`, so nested transactions cost nothing extra.
- **Rejected alternative:** setting the GUCs on connection *checkout* via an executor hook. Rails
  8's `with_connection` pooling can hand a *different* connection to a later query, silently
  dropping the correlation. Statement-level stamping has no such hole, because each connection
  stamps itself on first use.
- **Naming:** the implementation uses an `audit.*` GUC prefix rather than `app.*`, so a host
  application's own `app.*` settings cannot collide with it.

### 6.2 `Current` holds primitives, not records

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :request_id, :caused_by_request_id
  attribute :actor, :actor_type, :actor_id, :actor_label
  attribute :ip, :user_agent, :source

  # Convenience writer for entry points that have the record in hand.
  def actor=(record)
    super
    self.actor_type  = record&.class&.name
    self.actor_id    = record&.id
    self.actor_label = Audit::ActorLabel.for(record)
  end
end
```

The identity is stored as three plain values, and `actor` is only a convenience. This matters for
jobs (§6.4): a worker can populate the audit identity with **no database query and no risk of
`ActiveJob::DeserializationError`** when the user has since been deleted. It also guarantees the
label written by the trigger and the label written by the event subscriber are the same string,
because both read `Current.actor_label`.

`Audit::ActorLabel.for` may touch associations, so it is called **once per entry point**, never
from the statement-level stamping hook (§6.1) — that path is far too hot to query from.

> ⚠️ **A nil actor must leave `actor_label` NULL, not store the string `"System"`.**
> **[corrected 2026-08-27]** The obvious `ActorLabel.for(nil) => "System"` has a subtle
> consequence: `ActiveSupport::CurrentAttributes#set` restores only the keys it was given, so
> restoring `actor: nil` runs the custom `actor=` writer, which then *writes* `"System"` into
> `actor_label` — and every subsequent out-of-band write on that thread is labelled as though a
> scheduled system process did it. NULL means "no correlated actor", which is what an out-of-band
> write *is*; render "System" at **display** time instead (§11.2 already specifies that). Otherwise
> a console session becomes indistinguishable from a genuine system action, which inverts the whole
> point of §9.
>
> **[followed up 2026-08-28]** Deferring "System" to display time means every screen has to render
> it, and one of them did not. `ActorLabel.display` is now the single definition of the fallback
> chain — snapshotted label, then bare identifier, then "System" — with `ActorLabel.linkable?`
> saying whether there is an actor to link to. The models delegate to it.
>
> The rule it exists to enforce: **a `GROUP BY` rollup hands the view a tuple, not a record**, so
> `actor_display` is not available there and the "who triggered it" table on `actions/show`
> re-spelled the chain by hand. The copy dropped the nil branch, and `actor_path(nil)` raises
> `UrlGenerationError` — so the screen did not degrade, it 500'd, the first time an actorless action
> reached it. That action was `audit.redaction` itself, whose rake task passes no actor. Rollups go
> through `audit_actor_cell`; `spec/preview.rb` renders both screens so neither goes unlooked-at
> again.

### 6.3 Web requests

```ruby
# app/controllers/application_controller.rb
before_action do
  # Server-side and UUIDv7: never request.request_id, which Rails will take from a
  # client-supplied X-Request-Id header. See §20.1.
  Current.request_id = SecureRandom.uuid_v7
  Current.actor      = current_user          # populates type / id / label in one assignment
  Current.ip         = request.remote_ip
  Current.user_agent = request.user_agent
  Current.source     = "web"
end
```

`Current` is reset by the executor at the end of every request, so nothing leaks between requests.

### 6.4 Background jobs

Jobs are a first-class entry point, not an afterthought: a large share of the data mutation an
auditor cares about happens in background jobs, and a job whose changes land with a NULL actor is
a hole in the log. The target stack is **Solid Queue**, so everything below is ActiveJob-first; see
"Solid Queue specifics" for what its database-backed queue adds.

#### The rule: inherit the actor, mint a new `request_id`

| Carried from the enqueuing context | Generated fresh per execution |
|---|---|
| `actor_type`, `actor_id`, `actor_label` | `request_id` |
| — recorded as `caused_by_request_id` — | `source = "job"` |

**Why inherit the actor:** the job acts on that person's behalf. If Jane clicks Submit and a job
finishes the work, the rows it writes are attributable to Jane, and her activity screen (§11.1)
must show them.

**Why not inherit the `request_id`:** three reasons, all of which bite in production.

1. A job that runs three days later would write `audit_changes` rows whose `request_id` points at
   an `audit_events` row in a partition three days back — the drill-down join in §11.1 would have
   to span the entire retention window instead of one page's date range.
2. A bulk job writing 500k rows under a user's request id makes that single action in her timeline
   expand to half a million children, which is the paper_trail readability problem returning by
   the back door.
3. Retries. Each attempt is a distinct execution that may partially succeed; collapsing them into
   one id makes it impossible to tell which attempt wrote what.

Carrying the origin as `caused_by_request_id` keeps the causal chain queryable — "show me the user
action that caused this job" is one indexed lookup — without any of that.

**Label is snapshotted at enqueue time,** not recomputed at perform time. The label reflects who
authorized the work when they authorized it, and it survives the user being deleted before the
job runs.

#### Implementation A — ActiveJob (recommended; the only option under Solid Queue)

```ruby
# app/jobs/concerns/audit_context.rb
module AuditContext
  extend ActiveSupport::Concern

  included do
    around_perform do |job, block|
      origin = job.audit_origin || {}
      Current.set(
        request_id:           SecureRandom.uuid_v7,  # a fresh action; v7 for index locality (§20.1)
        caused_by_request_id: origin["request_id"],   # ...linked to its cause
        actor_type:           origin["actor_type"],
        actor_id:             origin["actor_id"],
        actor_label:          origin["actor_label"],
        # No origin at all => nobody enqueued this; it came from the scheduler.
        source:               origin.present? ? "job" : "system"
      ) { block.call }
    end
  end

  attr_accessor :audit_origin

  # Captured in `serialize`, NOT in an around_enqueue callback: serialize runs on
  # every enqueue path including bulk (`perform_all_later` / `enqueue_all`), which
  # is documented to skip enqueue callbacks. `||=` means a retry keeps the original
  # origin rather than recapturing the retrying job's own context.
  def serialize
    self.audit_origin ||= {
      "request_id"  => Current.request_id,
      "actor_type"  => Current.actor_type,
      "actor_id"    => Current.actor_id,
      "actor_label" => Current.actor_label,
      "source"      => Current.source
    }.compact
    super.merge("audit_origin" => audit_origin)
  end

  def deserialize(job_data)
    super
    self.audit_origin = job_data["audit_origin"]
  end
end
```

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  include AuditContext
end
```

**That is the entire answer to "how should a job be structured": inherit from `ApplicationJob`.**
Nothing per-job. A job that does not subclass it is the only way to lose correlation, which the
test in §16 catches.

Note the payload rides in its own `audit_origin` key rather than in `arguments`. Job signatures
stay untouched, and nothing here is a GlobalID, so a deleted user cannot cause a deserialization
failure.

**Nested enqueues chain automatically.** A job enqueuing another job runs `around_enqueue` inside
its own `around_perform`, so the child records the parent's fresh `request_id` as its cause,
building a traversable chain from the originating click.

#### Implementation B — raw `Sidekiq::Job` classes (not needed for Solid Queue)

Kept for reference only. Solid Queue has no non-ActiveJob worker API, so this applies solely if a
project runs Sidekiq *and* has workers that bypass ActiveJob. It covers ActiveJob-over-Sidekiq too,
so **use one or the other, never both** — pick B if any raw workers exist, A otherwise.

```ruby
# lib/audit/sidekiq_middleware.rb
module Audit
  class SidekiqClientMiddleware
    include Sidekiq::ClientMiddleware
    def call(_job_class, job, _queue, _redis_pool)
      job["audit_origin"] ||= {
        "request_id"  => Current.request_id,
        "actor_type"  => Current.actor_type,
        "actor_id"    => Current.actor_id,
        "actor_label" => Current.actor_label,
        "source"      => Current.source
      }.compact
      yield
    end
  end

  class SidekiqServerMiddleware
    include Sidekiq::ServerMiddleware
    def call(_instance, job, _queue)
      origin = job["audit_origin"] || {}
      Current.set(
        request_id:           SecureRandom.uuid_v7,
        caused_by_request_id: origin["request_id"],
        actor_type:           origin["actor_type"],
        actor_id:             origin["actor_id"],
        actor_label:          origin["actor_label"],
        source:               "job"
      ) { yield }
    end
  end
end
```

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_client do |config|
  config.client_middleware { |chain| chain.add Audit::SidekiqClientMiddleware }
end

Sidekiq.configure_server do |config|
  # Client middleware on the SERVER too, so job-enqueues-job propagates the chain.
  config.client_middleware { |chain| chain.add Audit::SidekiqClientMiddleware }
  config.server_middleware { |chain| chain.add Audit::SidekiqServerMiddleware }
end
```

> ⚠️ **Ordering risk, and why A is recommended.** Rails resets all `CurrentAttributes` on
> `ActiveSupport::Executor` run/complete. Sidekiq wraps job execution in the Rails reloader, and
> whether the server middleware chain runs inside or outside that wrapper determines whether the
> `Current` values set above survive to `perform`. Sidekiq's ordering makes this work, but it is
> framework-internal and has moved between versions. `around_perform` (Implementation A) runs
> inside the executor by construction and cannot be affected. **Either way, prove it with the
> Phase-2 test in §16 rather than by reading source** — the test catches a regression here
> regardless of which framework changed.


#### Solid Queue specifics

Solid Queue is **ActiveJob-only** — there is no non-ActiveJob worker API to accommodate — so
Implementation A above is the whole story and the A-vs-B decision disappears. Four adjustments
matter, and none of them touch the audit schema.

**1. Exclude the Solid Queue tables — this is the one that will hurt if missed.** Solid Queue keeps
its queue *in Postgres*, and its tables churn violently: every poll, claim, release, and heartbeat
is a write. Auditing them would swamp `audit_changes` with rows no auditor will ever read.

```ruby
UNAUDITED = {
  # ... Rails internals, audit tables ...
  "solid_queue_jobs"                 => "queue backend, extreme churn",
  "solid_queue_ready_executions"     => "queue backend",
  "solid_queue_claimed_executions"   => "queue backend",
  "solid_queue_scheduled_executions" => "queue backend",
  "solid_queue_blocked_executions"   => "queue backend",
  "solid_queue_failed_executions"    => "queue backend",
  "solid_queue_recurring_executions" => "queue backend",
  "solid_queue_recurring_tasks"      => "queue backend",
  "solid_queue_processes"            => "queue backend",
  "solid_queue_semaphores"           => "queue backend",
  "solid_queue_pauses"               => "queue backend",
}
```
The same applies to `solid_cache_entries` and `solid_cable_messages` if those are adopted.

**2. Run the queue in its own database, and guard the transaction stamp.** This is Rails 8's
default posture and it matters here for a reason beyond convention: `Audit::TransactionStamp`
prepends `begin_db_transaction` on the *PostgreSQL adapter class*, so without a guard it fires on
every Solid Queue connection too — adding a round trip to each poll and claim on the busiest
transaction path in the system. The guard sketched in §6.1 as `STAMPED_DATABASES` — shipped as
`config.correlated_databases`, renamed because the constant read as though it decided what was
audited, which it does not — reduces that to a string comparison. Verify it with a benchmark in Phase 2: Solid Queue's polling frequency makes this the
one place where a stray round trip is actually measurable.

If the queue shares the primary database instead, the exclusion list in (1) still keeps the audit
log clean, but the stamping overhead is unavoidable — another reason to separate.

**3. Enqueue after commit.**  **[corrected 2026-08-27]** With a separate queue database, a job
enqueued inside a transaction that later rolls back **still runs**, and its writes would be
attributed to a user action that never happened.

> ⚠️ **`config.active_job.enqueue_after_transaction_commit` in `config/application.rb` does
> nothing.** ActiveJob's railtie explicitly strips that key out of the global config — the comment
> in `activejob-8.1.3.1/lib/active_job/railtie.rb:58-64` reads *"This config can't be applied
> globally, so we need to remove otherwise it will be applied to `ActiveJob::Base`."* It is a
> `class_attribute` (default `false`), and in the 8.x line it is a **boolean**, not the `:all` this
> section originally specified. Set it on the job class:

```ruby
# app/jobs/application_job.rb — or in the AuditLog::JobContext concern's `included do` block
self.enqueue_after_transaction_commit = true
```
Now the enqueue is deferred until the enclosing transaction commits, so a rolled-back action
produces no job, no audit event, and no change rows — the atomicity guarantee in R3 extends across
the job boundary. Assert it in a spec; a silently-ignored config setting is exactly the kind of
thing that looks fine forever.

**4. Recurring tasks are the `source: "system"` case.** `config/recurring.yml` enqueues with no
originating request, so `audit_origin` comes back empty and the `around_perform` above derives
`source: "system"` automatically — no base class or per-job configuration needed. These render as
**System** in the UI, distinct from a job a user caused.

> ⚠️ **Bulk enqueue.** `ActiveJob.perform_all_later` / Solid Queue's `enqueue_all` are documented as
> skipping the `enqueue` callbacks. This is exactly why the origin is captured in `serialize`
> rather than in an `around_enqueue` hook above — `serialize` runs for every enqueue path, bulk
> included. Confirm with a test that bulk-enqueued jobs carry `audit_origin`; if that ever
> regresses, every bulk-enqueued job silently loses its actor.

#### Scheduled and system jobs

A cron-triggered job has no enqueuing context: `audit_origin` is empty, so `actor_*` stay NULL and
`source` should be set to `"system"`. Its changes render as **System** in the UI. Set this
explicitly in the recurring job's base class rather than leaving it as `"job"` — an auditor needs
to distinguish "nobody did this, the schedule did" from "a user's request caused this."

#### Making job activity legible

Every job execution mints a `request_id`, so a job that mutates data but emits no domain event
produces `audit_changes` rows with no narrative row — and shows up in the §11.5 reconciler forever.
Default `ApplicationJob` to closing the loop:

```ruby
class ApplicationJob < ActiveJob::Base
  include AuditContext

  class_attribute :emit_audit_event, default: true
  def self.skip_audit_event! = self.emit_audit_event = false

  around_perform do |job, block|
    block.call
    if emit_audit_event
      Rails.event.notify("job.performed", job_class: job.class.name,
                                          job_id: job.job_id, executions: job.executions)
    end
  end
end
```

Cost is one `audit_events` row per job execution. For a high-volume, non-mutating queue call
`skip_audit_event!` on that class — its record-level changes (if any) are still captured by the
trigger regardless, so the opt-out reduces narrative noise, never audit coverage.

### 6.5 Console, rake tasks, and migrations

These deliberately leave `Current.request_id` blank, so `Audit::Context.apply!` no-ops and the
trigger writes `request_id IS NULL` — the out-of-band signal §9 is built around. Two refinements
worth making, both described in §9: prompt for a reason when a production console opens and stamp
a session-scoped `request_id`, and have migrations stamp `source: "migration"` with the version.

---

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

---

## 7. Layer 2 via Rails 8.1 structured events

Rails 8.1 ships `Rails.event` (`ActiveSupport::EventReporter`): `notify(name, **payload)`,
`tagged`, `set_context`, `debug` / `with_debug`, and subscribers registered with
`Rails.event.subscribe(subscriber)` implementing `#emit(event)`. Events carry name, payload, tags,
context, a nanosecond timestamp, and source_location.

**It is an emission and fan-out API, not a log.** It has no durability, ordering, or transactional
guarantee, and it does not hook ActiveRecord. We use it as the front door so domain code declares
*what happened* exactly once and stays ignorant of where the record lands:

```ruby
# app/models/order.rb
Rails.event.notify("order.submitted", order_id: id, total_cents: total_cents, line_count: lines.size)
```

Two subscribers consume it: `Audit::EventSubscriber` writes durably to `audit_events`, and the
observability subscriber ships to Honeybadger/Datadog. Analytics events simply never appear in the
registry below, so they reach observability and not the audit table.

### The registry — an intentional audit surface

Auditors like a finite, reviewable list of what the system considers an auditable action. An
allowlist gives us that, and gives the human sentence a home:

```ruby
# config/initializers/audit_registry.rb
Audit::Registry.register "order.submitted",
  subject: ->(p) { ["Order", p[:order_id]] },
  summary: ->(p) { I18n.t("audit.order.submitted", count: p[:line_count],
                                                   total: Money.from_cents(p[:total_cents])) }
```

```ruby
class Audit::EventSubscriber
  def emit(event)
    entry = Audit::Registry[event[:name]] or return
    subject_type, subject_id = entry.subject.call(event[:payload])

    AuditEvent.create!(
      request_id:   Current.request_id,
      action:       event[:name],
      actor_type:   Current.actor&.class&.name,
      actor_id:     Current.actor&.id,
      actor_label:  Current.actor_label,                    # SNAPSHOT, same string the trigger saw
      subject_type: subject_type,
      subject_id:   subject_id,
      source:       Current.source,
      ip:           Current.ip,
      user_agent:   Current.user_agent,
      summary:      entry.summary.call(event[:payload]),    # SNAPSHOT, rendered now
      metadata:     event[:payload].merge(
                      caused_by_request_id: Current.caused_by_request_id
                    ).compact
    )
  end
end
```

- The `summary` string is **rendered at write time and stored**, not re-rendered at display time.
  A copy edit to an I18n key must not alter the historical record (R6).
- `create!` joins the ambient transaction, so a rollback discards the audit event along with the
  change. Correct behavior — and the reason not to defer this to `after_commit` or a job.
- **Verified 2026-08-27 — it does swallow them.** `ActiveSupport::EventReporter#notify` rescues
  every subscriber exception and reports it to the error reporter as `handled: true`
  (`activesupport-8.1.3.1/lib/active_support/event_reporter.rb:393`). `raise_on_error` defaults to
  `false` and **nothing in Rails sets it**, so a failed `audit_events` write would be silent: the
  change rows it was describing commit anyway and no one is told. For an ordinary observability
  subscriber that default is right; for this one it is not.

  The reference implementation sets `Rails.event.raise_on_error = true` in the engine's
  initializer, so a failed audit write raises and rolls back the action it was describing — which
  is what R3 actually asks for. The trade is that an unrelated subscriber raising will now also
  fail the request; if a project has noisy third-party subscribers, wrap this subscriber's write
  instead and keep the flag off.

### Actor labels

```ruby
module Audit::ActorLabel
  def self.for(actor)
    case actor
    when nil     then "System"
    when User    then "#{actor.full_name} <#{actor.email}>"
    when ApiKey  then "API key #{actor.name} (##{actor.id})"
    else              "#{actor.class.name}##{actor.id}"
    end
  end
end
```

The label is resolved once per entry point and **snapshotted onto every row**, so
that renaming or deleting a user cannot retroactively change what the log says
happened (R6). Contrast §11.8, where association ids in a diff are labelled by a
*live* lookup at display time — legitimate there only because that label annotates
a stored id rather than replacing it.

---

## 8. Partition management & retention

Monthly range partitions on `occurred_at` for both tables, provisioned by **a small scheduled
job**: a daily recurring task (`config/recurring.yml` under Solid Queue) that ensures partitions
exist for the current month plus the next three, and fails loudly if it cannot. A missing future
partition is a production outage on the *write path*, so alert on it.

**`pg_partman` was reconsidered and rejected.** [revised 2026-08-27] An earlier revision of this
section listed it as the preferred option. Measured against the reference implementation it would
replace ~65 of `partitions.rb`'s 103 code lines — 2.5% of the library — and would not replace the
parts that carry the risk:

- **Scheduling does not go away.** `run_maintenance_proc()` still needs a caller: pg_cron (another
  extension, another availability matrix), `pg_partman_bgw` (needs `shared_preload_libraries` and a
  restart, generally unavailable on managed Postgres), or a rake task — at which point the thing
  being replaced is Ruby-that-creates-partitions with Ruby-that-calls-SQL-that-creates-partitions,
  and the failure mode ("nobody ran the rotation") is identical.
- **The UTC-boundary hazard does not go away.** partman derives bounds with `date_trunc` against the
  maintenance session's `TimeZone` — precisely the defect described below — except the boundary then
  depends on whoever invokes maintenance and is not ours to fix. `misaligned_bounds` becomes *more*
  valuable under partman, not less.
- **It breaks §2.4's "no extensions",** which is what makes this installable from an ordinary
  migration with no superuser. Install becomes "confirm your provider ships it, get elevated
  privileges to `CREATE EXTENSION`, and make sure CI's Postgres image has the binaries" — and
  `structure.sql` then carries `CREATE EXTENSION pg_partman` for every `db:test:prepare`. Most large
  managed providers offer it; Heroku's fixed extension list does not.
- **Scale mismatch.** partman solves sub-partitioning, retention schemas, template tables, epoch
  keys and background workers. This needs "one monthly partition, three months ahead". For a library
  whose pitch is *nothing bypasses it and you can read all of it*, that is a poor trade.

What partman is genuinely better at is retention and relocating rows stranded in the default
partition. Both are implemented directly instead — see below.

**A DEFAULT partition is worth considering as a backstop.** [added 2026-08-27] With one, a missed
rotation degrades from "every audited write in the application fails" to "rows land in the wrong
place and a report says so". The cost is real and needs stating: while rows sit in the default
partition, `ATTACH`ing a partition covering their range fails, because Postgres must scan the
default partition and reject overlapping rows. So a default partition is only safe if something
actively watches it — the reference implementation exposes `AuditLog::Partitions.overflow_count`
and the rotation task warns on it. With solid alerting on the rotation job, omitting it is equally
defensible; without, take the backstop.

**Every boundary must be UTC midnight, and the DDL must say so explicitly.** [added 2026-08-27]
Two distinct things were wrong in the reference implementation and are now fixed:

1. `CREATE TABLE ... PARTITION OF ... FOR VALUES FROM ('2026-09-01')` passes a **bare date**, which
   Postgres resolves against the session `TimeZone` **at DDL time**. Run from Rails (which sets
   `SET time zone 'UTC'`) it produced UTC-midnight bounds; run from `psql` against a server whose
   default zone was `America/Detroit` it produced bounds five hours off. Adjacent months created
   under different zones then either **overlap** (`CREATE` fails) or leave a **gap** — and rows
   falling in a gap land in the default partition, which *blocks* attaching the real one. Pin the
   offset in the literal: `'2026-09-01 00:00:00+00'`.
2. The month arithmetic deciding *which* partitions to create and freeze used `Date.current`, which
   follows `Time.zone`. In an app configured to a US zone that is hours **behind** UTC, so on the
   last day of a month it names the previous month and drifts one partition out of step with the
   data. Use UTC for boundary arithmetic.

UTC is not a preference here. `occurred_at` is `timestamptz` — an absolute instant with no zone of
its own — so UTC is the only non-arbitrary boundary; and UTC has no DST, whereas a boundary in a
DST-observing zone sits 23 or 25 hours from its neighbour twice a year. Expose a
`misaligned_bounds` check and warn from the rotation task; a partition created by hand is otherwise
undetectable until it produces a gap.

Note the deliberate asymmetry with §11.0's date filters, which are built in `Time.zone` because a
UI date range is a human's calendar day. The consequence is that an app-zone range crosses a UTC
month boundary and touches **one extra partition** — a known `+1`, and cheaper than the alternative.
It also corrects §17's claim that every bounded screen prunes to a single partition: it is one *or
two*, and the benchmark should report the count rather than assert one.

Finally, `pg_dump` renders `timestamptz` in the client's zone, so `structure.sql` records correct
UTC bounds as rotating local offsets (`'2026-07-31 20:00:00-04'`). That reloads exactly — the offset
is explicit — but it reads to a reviewer as though the months are misaligned and it shifts across
DST. Set `PGTZ=UTC` for dumps.

**Retention.** [implemented 2026-08-27] `config.retention`, default **7 years**
(the reference app's `ROLLOUT.md` Q2, decided 2026-08-27);
`nil` disables it. A partition expires when its **upper** bound is older than the horizon, never its
lower — the lower bound would retire a month that still holds in-horizon days.

`config.retention_action` defaults to `:detach`, not `:drop`. Detaching is reversible with a single
`ATTACH`, so a wrong horizon costs an afternoon; dropping is not, and an audit log is the worst
table in the database to discover a wrong setting in. A detached partition keeps its rows and its
disk under a `_retired_` name, and the rotation task reports it with its size so it cannot pile up
unseen. The rename is load-bearing twice over: it makes "expired, awaiting export" a visible state,
and it stops `create_month!` mistaking a retired table for a live partition. Detach-then-export-
then-drop, never drop-then-hope — so the export step is what `:drop` is still waiting on, not the
horizon.

**Export, then drop.** [implemented 2026-08-28, ROLLOUT Q8] `AuditLog::Archive` streams a retired
partition to a local gzipped CSV plus a manifest, and `drop_exported!` drops only what verifies.

**`COPY ... TO STDOUT`, and nothing else.** The constraint is managed Postgres, and every other
option fails on at least one provider: `COPY TO '/path'` writes on the *server* and needs superuser
plus a filesystem you do not have; `COPY TO PROGRAM` needs superuser; `aws_s3.query_export_to_s3`
is an RDS-only extension that ties the library to one cloud; Cloud SQL's export API is GCP-only and
runs outside the application entirely; `pg_dump -t` needs the binary, a second set of credentials,
and a client version matching the server. `COPY ... TO STDOUT` streams through the connection the
application already has — no server filesystem, no superuser, no extension, no extra credentials,
identical on RDS, Aurora, Cloud SQL, Azure Flexible and plain self-hosted.

**Where the file goes is not this library's business.** It writes a local file and stops. Uploading
to S3 or GCS is a deployment decision, and baking one in is exactly what would make this
un-copyable. `config.archive_dir` names the local directory; the rake task says so out loud.

**The manifest is the point.** It records row count, SHA-256, byte size and column list, and
`drop_exported!` refuses any partition that does not verify against *both* halves: the checksum
catches a truncated or corrupt write, and the row count catches an export taken against a different
partition or before more rows arrived — which a checksum alone cannot see. Verification failures are
re-raised as `VerificationError`, including unreadable-file errors from Zlib, so that one bad export
is a **reported refusal** rather than an exception that aborts the run and leaves the partitions
after it silently unprocessed.

The artifact is deliberately plain: gzip and CSV, readable with `gzcat` and any CSV reader, with no
dependency on this library ever existing. Detach, export, verify, drop — never drop-then-hope.

**Draining the default partition.** [implemented 2026-08-27] The trap noted above — rows in the
default partition *block* creating the partition that should hold them — needs a way out, or the
backstop converts a write-path outage into a permanent one. `drain_default!` stages the rows into a
temp table, creates the real partitions, and inserts them back so routing files them correctly; one
transaction, so a failure leaves them exactly where they started, still queryable through the
parent, ids preserved. It computes the target month as
`date_trunc('month', occurred_at AT TIME ZONE 'UTC')`: `date_trunc` on a bare `timestamptz`
truncates in the session zone and files boundary rows into the wrong month.

**Rolling months up into years.** [implemented 2026-08-27] A 7-year horizon at monthly granularity
is 84 partitions per table, 168 in total — every one a relation the planner considers, autovacuum
tracks and `pg_dump` walks. `rollup!` consolidates any calendar year older than
`config.rollup_after` (2 years) into one yearly partition, taking that to ~5 yearly partitions plus
a rolling window of months.

**There is no `ALTER TABLE ... MERGE PARTITIONS` in PostgreSQL.** The patch was reverted before 17
shipped and is absent from 18 — verified against 18.6, where both `MERGE PARTITIONS` and
`SPLIT PARTITION` are syntax errors. Do not plan around it. The rollup is a hand-rolled
copy-and-swap, staged so the exclusive lock covers catalog work only:

1. Build a standalone table with `LIKE parent INCLUDING ALL` and fill it from the year's partitions.
   The parent is untouched and the application keeps writing. `INCLUDING ALL` carries the indexes,
   so `ATTACH` matches them against the parent's partitioned indexes instead of rebuilding them
   under the lock; a validated `CHECK` matching the future bound lets `ATTACH` skip its own
   validation scan — the same work, paid outside the lock.
2. One short transaction: detach the twelve monthlies, `ATTACH` the new table, drop the redundant
   `CHECK`, drop the monthlies.

Correctness rests on the year being closed, and that is **asserted, not trusted**: an id watermark
taken *before* the copy is re-checked after the detach, and one row that arrived in between rolls
the swap back. Before rather than after, because a watermark read after the copy would not catch a
row that landed *during* it — precisely the row that would be lost.

A rollup that dies after the copy but before the swap leaves its staging table under the target
name, holding a full year of audit data. It carries a table comment marking it as this library's
debris, which is the only thing separating "safe to recreate" from "somebody else's table, and
dropping it destroys data" — so `rollup_year!` refuses an unmarked table rather than reaching for
`DROP TABLE IF EXISTS`. `orphaned_rollups` reports marked debris with its size and the rotation
task warns about it, because a staging table is not a partition and nothing else would ever
mention it. [added 2026-08-28]

Two costs to state plainly. It rewrites a full year of data. And it coarsens retention: a yearly
partition can only be retired whole, so up to eleven extra months are kept past the horizon. Both
are acceptable for cold years and neither is for warm ones, which is what `rollup_after` bounds.

**Only the rotation task belongs in a cron.** `drain_default!`, `rollup!` and `retire!` each take
`ACCESS EXCLUSIVE` on an audit table, which blocks every audited write in the application. All three
run under `config.maintenance_lock_timeout` (5s): a pending `ACCESS EXCLUSIVE` request blocks every
lock request queued behind it, so an unbounded wait behind one long-running reader stalls the audit
write path for the whole application. Failing fast and reporting beats a maintenance task that takes
production down.

Because `audit_changes` will be the largest table in the database, keep an eye on:
- Autovacuum settings — the table is insert-only, so freezing behaviour matters far more than
  dead-tuple thresholds. Have the rotation job run an explicit `VACUUM FREEZE` on each partition
  once its month closes: the partition is immutable from that point, and freezing it deterministically
  beats waiting for an anti-wraparound vacuum to storm through the largest table in the database
  months later. On PG 18, eager freezing handles the *current* partition too (§20.2).
- `fillfactor` is irrelevant (no updates).
- Consider `CREATE INDEX CONCURRENTLY` on new partitions only, not the parent, if index build time
  on the parent ever becomes an issue.

---

### The three manual operations cannot overlap  **[added 2026-08-28]**

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

---

## 9. Out-of-band writes

A row in `audit_changes` with `request_id IS NULL` means the change was made outside a correlated
request: a `rails console` session, a migration, a rake task, a manual `psql` connection.

This is a feature. The auditor UI must surface these prominently rather than hiding them — they
are the highest-scrutiny events in the entire log. Two follow-ons:

- Add an `audit:console` initializer that prompts for a reason when `Rails.env.production?` and the
  console is opened, sets `Current.request_id` to a fresh uuid, and writes an `audit_events` row
  (`action: "console.session_opened"`, `source: "console"`). Cheap, and it converts the scariest
  category of write into a narrated one.
- Migrations legitimately produce uncorrelated changes. Consider a wrapper that stamps
  `source: "migration"` with the migration version in `metadata`.

---

## 10. Bulk operations and the bypass

Trigger overhead is a small fraction of the cost of a normal OLTP write, but it is real on bulk
loads — a 500k-row import writes 500k audit rows.

Provide one explicit escape hatch:

```ruby
Audit.without_logging(reason: "Nightly ERP sync", actor: Current.actor) do
  # sets app.audit_bypass = 'on' via SET LOCAL for the transaction
end
```

**The bypass logs itself.** Before disabling, it writes an `audit_events` row
(`action: "audit.bypass"`, with reason, actor, and — after the block — affected row counts). An
un-narrated gap in the log is a finding; a narrated one is a control.

Restrict it: the helper should raise unless called from an allowlisted set of classes, so it cannot
become a convenient way to make an inconvenient change quietly.

---

## 11. Query & UI cookbook

This section exists because a schema that stores the right data can still fail to *answer*
anything. Each canonical question below is specified as: the screen, the query, the index that
serves it, and the trap to avoid.

### 11.0 Two rules that govern every screen

**Rule 1 — every screen carries a bounded date range.** Partition pruning is the entire
performance story. Default every screen to the last 30 days and require an explicit range
otherwise. An unbounded "all time" filter scans every partition of the largest table in the
database. Either forbid it in the UI or route it to a background export job.

**Rule 2 — paginate by keyset, never by offset, and never render a total count.**
`OFFSET 200000` re-reads every skipped row, and `SELECT COUNT(*)` over millions of rows blocks the
page. Use Pagy's keyset pagination (`Pagy::Keyset`, Pagy 9+) ordered by `(occurred_at DESC, id DESC)`
— unique because `id` comes from one sequence shared across all partitions. Where a count is
genuinely wanted, show "1–50 of many" via `Pagy::Countless`.

**Implemented 2026-08-28** in `AuditLog::Pagination`, replacing the fixed row caps (50 events, 100
actions, 200 changes) the screens shipped with. Those caps were a *silent* truncation: an auditor
asking what Jane did last week saw the newest 50 with nothing on the page saying there were 500 —
the same failure the drill-down date bound exists to prevent.

Three properties are worth stating because each one is a way this could have gone wrong:

1. **The keyset predicate is ANDed onto the screen's date range, never substituted for it.** Rule 1
   bought partition pruning; Rule 2 must not spend it. `pagination_spec.rb` asserts `occurred_at`
   survives in the paged query.
2. **A cursor that does not belong to the screen falls back to the newest page.** Pagy raises
   rather than guessing when the cursor's keys do not match the ordering, and the recovery has to
   be visible — silently applying a mismatched cursor would drop rows off an audit screen.
3. **The last page says "End of results."** A fixed cap could only imply it.
4. **The cursor carries microseconds.** Pagy builds it with `to_json`, and ActiveSupport renders a
   `Time` at `ActiveSupport::JSON::Encoding.time_precision` — which defaults to **3**, milliseconds.
   `occurred_at` is `clock_timestamp()`, i.e. microseconds, and in practice every row carries
   sub-millisecond digits. A truncated cursor names an instant slightly *earlier* than the row it
   was minted from, so the next page's `occurred_at < cursor` skips everything in the gap and rows
   vanish between pages — the precise failure this replaced the row caps to prevent, reintroduced
   by a default. It surfaced as a one-in-eight flake, because it needs a row to land inside that
   sub-millisecond window at a page boundary. Fixed with a `jsonify_keyset_attributes` lambda
   scoped to the cursor, rather than by raising the global `time_precision`, which would change
   every JSON response the host application renders.

`config.page_size` (50) is a rendering choice with no cost curve behind it: there is no OFFSET to
grow and no COUNT to compute. The dashboard keeps fixed limits deliberately — its lists are "10
most recent" summary widgets, not browsable result sets.

Both models are read-only (`def readonly? = persisted?` — **not** `= true`, which breaks inserts
and silently disables layer 2; see §12) and paired with a query object per screen.

---

### 11.1 Q1 — "What did Jane Doe modify or delete last week? Or on a specific date?"

**Screen:** *Actor Activity*. Filter bar = actor picker, date range, source, operation. Body = one
row per action, newest first, expandable to the field-level diffs it produced.

```ruby
# app/queries/audit/actor_activity.rb
class Audit::ActorActivity
  def initialize(actor:, range:)
    @type, @id, @range = actor.class.name, actor.id, range
  end

  # Narrative layer — one row per business action, already carrying actor_label + summary.
  def events
    AuditEvent.where(actor_type: @type, actor_id: @id, occurred_at: @range)
              .order(occurred_at: :desc, id: :desc)
  end

  # Record layer — COMPLETE, independent of the event registry. This is what
  # "modify or delete" literally means, and it is the compliance-grade answer.
  def changes(operations: %w[U D])
    AuditChange.where(actor_type: @type, actor_id: @id, occurred_at: @range)
               .where(operation: operations)
               .order(occurred_at: :desc, id: :desc)
  end
end
```

```ruby
Audit::ActorActivity.new(actor: jane, range: 1.week.ago.beginning_of_day..Time.current)
Audit::ActorActivity.new(actor: jane, range: Date.new(2026, 8, 20).all_day)   # a specific date
```

`Date#all_day` builds the range in `Time.zone`, which becomes a `timestamptz` bound and prunes
correctly — the auditor's calendar day, not UTC's.

**Indexes:** `audit_events (actor_type, actor_id, occurred_at DESC)` and
`audit_changes (actor_type, actor_id, occurred_at DESC)`.

**Drill-down without N+1.** Paginate the *events*, then fetch all their changes in one query:

```ruby
@pagy, @events = pagy_keyset(query.events, limit: 50)
@changes = AuditChange.where(request_id: @events.map(&:request_id))
                      .order(:occurred_at, :id).group_by(&:request_id)
```

One indexed query on `request_id` for the whole page. This is where the design pays off: the
40-record nested-attributes form submit renders as **one** expandable row listing "Order #4821 and
39 related records", not 40 rows the auditor has to mentally reassemble.

> ⚠️ **Do not build the actor timeline off `audit_events` alone.** The event registry (§7) is an
> allowlist, so `audit_events` is complete only for *registered* actions. A change made through a
> controller that never emitted a registered event exists in `audit_changes` and nowhere else. The
> screen must therefore offer both views — "Actions" (narrative, from events) and "All changes"
> (complete, from changes) — and §11.5 keeps the gap between them visible and shrinking.

---

### 11.2 Q2 — "All modifications to this model: by whom, when, and which fields?"

**Screen A — record history tab** (`/orders/4821/history`):

```ruby
AuditChange.where(record_type: "Order", record_id: order.id)
           .order(occurred_at: :desc, id: :desc)
```
Index: `(record_type, record_id, occurred_at DESC)`. This is a tight index scan regardless of how
large the table gets, and it is the one screen where an unbounded range is acceptable — a single
record has bounded history. It will still touch every partition, so cap it at, say, the most recent
200 changes with a "load older" control.

**Screen B — all records of a class in a window:**

```ruby
AuditChange.where(record_type: "Order", occurred_at: range)
           .order(occurred_at: :desc, id: :desc)
```
Index: `(record_type, occurred_at DESC)` — added specifically for this. Without it, the
`(record_type, record_id, occurred_at)` index degrades to scanning every row of that type in range.

**Narrowed to specific fields** — "every time anyone touched `status` or `total_cents`":

```ruby
scope.where("changed_columns && ARRAY[?]::text[]", %w[status total_cents])
```
Index: GIN on `changed_columns`.

> ⚠️ **This is why `changed_columns` exists.** The intuitive query is `diff ? 'status'`, and it has
> two independent traps. First, in ActiveRecord `?` is a bind placeholder, so the jsonb operator
> must be written `??` or as `jsonb_exists(diff, 'status')`. Second — and this one is silent — a
> GIN index built with `jsonb_path_ops` **does not support `?` at all**; the planner drops to a
> sequential scan and nothing warns you. The `text[]` column sidesteps both, indexes smaller, and
> doubles as the display list of changed fields.

**Attaching user names — nothing to attach.** `actor_label` is denormalized onto every
`audit_changes` row (§4), so this grid needs no join, no preload step, and no lookup table. The
label is the point-in-time snapshot the trigger saw, so it stays correct after the user is renamed
or deleted, and it matches the label on the corresponding `audit_events` row exactly — both come
from the same `Current.actor_label` string computed once per request.

Render `User #17` as the fallback when `actor_label IS NULL` (an out-of-band write, §9), and
`System` when `actor_type IS NULL`.

**The actor-picker dropdown** should be sourced from `users`, not from the audit log — an auditor
searching for "Jane Doe" wants to find her whether or not she has activity in the current window,
and `SELECT DISTINCT actor_id` over `audit_changes` would be unusable at volume. Deleted users are
the only gap; if the picker must include them, add a nightly-refreshed materialized view over
`audit_changes` rather than a live-maintained table. Deferred until the UI proves it needs it.

**Rendering the diff.** Each `diff` value is `[old, new]`:

| Shape | Meaning | Render as |
|---|---|---|
| `["pending", "approved"]` | changed | Pending → Approved |
| `[null, "approved"]` | set on insert, or was null | *(not set)* → Approved |
| `["approved", null]` | **cleared** | Approved → *(cleared)* |
| whole row, `operation = 'D'` | record deleted | full final-state table, styled as a deletion |

"What fields did they change or delete" is answered by `changed_columns` directly — no jsonb
parsing needed for the summary column, only for the expanded detail.

---

### 11.2a Q2, narrative half — "What was *done* to Order #4821, in words?"  **[added 2026-08-28]**

Screens A and B above answer Q2 from `audit_changes`: complete by construction, field-level, and
the compliance-grade answer. They are not the answer to *"what happened to this order"* as a human
would ask it. That one is a list of sentences, and it lives in `audit_events`.

The storage for it has been here since the first migration and nothing read it. `subject_type` /
`subject_id` (§4) is what a Registry entry's `subject:` lambda populates, and
`(subject_type, subject_id, occurred_at DESC)` is indexed specifically for this lookup — but until
`AuditLog::RecordTimeline`, `AuditLog::Redaction` was its only consumer. The gap was in this
document too: §11.4's table listed the record screen as `audit_changes` alone.

```ruby
AuditEvent.where(subject_type: "Order", subject_id: order.id)
          .order(occurred_at: :desc, id: :desc)
```

Unbounded in range for the same reason Screen A is: a single record has bounded history. Keyset
paged, so unbounded does not mean unlimited.

**Two populations, and merging them would lie.** An action can touch a record without naming it:

| | Named this record as `subject` | Wrote to it under some other subject, or none |
|---|---|---|
| Example | `order.submitted` | `price.bulk_adjusted`, a nested save whose subject is the parent, an entry registered with no `subject:` |
| Found by | the subject index | matching `request_id` against the record's own `audit_changes` rows |
| Cost | one index scan | two steps — and the second needs a date bound |
| Complete? | for registered actions that set `subject:` | only within the change rows it scanned |

They render as two sections, not one merged list, because the difference between *"this action was
about this record"* and *"this action happened to write to this record"* is a real difference in
what the log is claiming — and because only the second is capped. A merged list would present both
claims identically and hide the cap in the middle of it.

**The correlated half carries two bounds, both disclosed.**

*A date bound*, because `WHERE request_id IN (...)` prunes no partitions — §11.6's whole argument,
applied to a second query. The record's own change rows supply both the ids and a real window, so
the bound infers nothing.

*A scan cap*, because the ids come from the record's change history and that history is unbounded.
The cap is stated on the screen as what it actually is — *"read from the 50 most recent change rows
for this record"*, a claim an auditor can check — and it is escapable with `?scan=`, the same
treatment §11.6 gives the drill-down's window. An unqualified "recent activity" heading over a
silently truncated list is the failure this library exists to prevent, in miniature.

> ⚠️ **`where.not(subject_type: t, subject_id: i)` is the wrong exclusion and fails silently.**
> It compiles to `NOT (subject_type = t AND subject_id = i)`, which evaluates to NULL — and so
> excludes the row — whenever `subject_type IS NULL`. An action registered without a `subject:`
> lambda is exactly that row, and it is the single most important thing the correlated section is
> there to surface: the natural spelling drops the entire population the section exists for, and
> the screen still renders. Use the row-wise `(subject_type, subject_id) IS DISTINCT FROM (?, ?)`,
> which is null-safe in both columns.

**What this does not change.** The narrative tab is a reading aid, not a compliance answer. An
action with no Registry entry, or one registered without `subject:`, is invisible to the first
section and reachable by the second only if it wrote a change row inside the scan window. The
change rows remain the complete record and stay the landing tab, and a `?view=` the URL does not
recognise falls back to them rather than to the capped list.

---

### 11.2b The host-facing timeline — `AuditLog::Timeline`  **[added 2026-08-28]**

Everything above is the auditor's UI. This is the other audience: a host application putting an
*"activity history"* on its own `orders/show`, in its own markup, for its own staff.

**Why value objects and not relations.** The auditor screens encode rules that are invisible from
outside the gem — that a diff value's three nil shapes mean different things (§11.2), that a nil
actor renders "System" but is never stored that way (§6.2), that a redacted payload and an absent
one are the same empty jsonb and only the marker separates them (§13), that an association label
annotates a recorded id and must never replace it (§11.8), that `LabelResolver` has four outcomes
and not two. Ship the relations alone and every host app re-derives those. Some get them wrong, on
a screen that looks fine. `Timeline::Entry`, `FieldChange`, `TouchedRecord` and `Actor` exist to
make each of those rules a method call.

**The grain is the unit of work, not the audit row.** A form submit that saves an order and forty
line items is ONE entry — the order's own field changes on it, the forty line items beside it —
rather than forty rows a reader reassembles. That is what a correlation id was for (§3). An
uncorrelated write (`request_id IS NULL`, §9) correlates to nothing by definition and stands alone.

**Spine A: `audit_changes` is the backbone.** The record's own change rows, keyset-paged on
`(record_type, record_id, occurred_at DESC)` — the same scan Screen A uses — then grouped.

| | |
|---|---|
| Buys | completeness for every **write**. Nothing that modified this record can be missing, whatever path it took, because layer 1 captured it regardless of the registry. |
| Costs | an event that named this record as its subject but wrote no change row *to it* does not appear. `order.emailed`, where the write lands in `deliveries`, is that shape. |
| Mitigation | `RecordTimeline#events` and the Actions tab still list it. Closing the gap means unioning both tables into the spine, which changes the keyset — see below. |

**The page-boundary rule.** An entry is hydrated with *every* change row of its unit of work,
including rows past the end of the page — that is what keeps a unit of work whole at a cursor
instead of splitting it in half. The cost is that the next page begins at one of those older rows
and would render the same entry again.

So: **an entry whose newest row for this record is newer than the page's own newest row was
necessarily shown in full on an earlier page, and is dropped.** The check is local and stateless —
no cursor bookkeeping to keep in sync — and it can only ever drop a duplicate. On the first page
nothing is newer than the head; for the ordinary one-row-per-request entry the row *is* the max.

**`headline` returns nil rather than a generated sentence, and that nil is the contract.** The
library does not compose *"Jane updated status and total"* from column names. Three reasons, and
the third is the one that matters:

1. It would be this gem's phrasing, not the app author's.
2. It would re-render differently after a gem upgrade, while a stored `summary` is frozen at emit
   time and never changes.
3. On the page it would be **indistinguishable from a summary that was frozen at emit time** — a
   recomputed sentence wearing the costume of immutable history.

Same discipline as `RecordLabel`'s chain ending in nil (§11.8). The host has i18n, knows what its
models are called, and may have STI names the gem could never guess; it gets `operations`,
`record_type` and `changed_columns` and writes its own sentence. `kind` (`:narrative` /
`:change_only`) says which it is holding.

**`config.record_url` is nil by default and the default is not a placeholder.** Inferring
`product_path` from `"Product"` is the same mistake as sniffing a `name` column for a label, and it
fails at render time on a screen an auditor is reading. Silence is the opt-out; the value objects
render fine without it. It serves actors too — an actor is a record.

**Authorization is deliberately not in this object.** The gem exposes everything and the host gates
it, because "admins only" or "admin and staff" is a policy question about the host's own roles that
no config lambda here would express better than the host's existing authorization layer. The
auditor UI's `config.authorize` gates the auditor UI; a host-rendered timeline is the host's screen.

**The engine renders this tab from the value objects**, not from its own relations. A presenter
nothing in the gem consumes drifts from what the auditor UI actually does — the same argument that
makes one `Coverage` back both the rake task and the shared example.

**Still open (Spine B).** Union both tables into the spine so a write-less event appears:

```sql
SELECT request_id, max(at) AS at FROM (
  SELECT request_id, max(occurred_at) at FROM audit_changes
    WHERE record_type = $1 AND record_id = $2 AND request_id IS NOT NULL GROUP BY request_id
  UNION ALL
  SELECT request_id, max(occurred_at) at FROM audit_events
    WHERE subject_type = $1 AND subject_id = $2 GROUP BY request_id
) u GROUP BY request_id ORDER BY at DESC, request_id DESC
```

Keyset on `(at, request_id)` is clean — one row per `request_id`, and a UUIDv7 is totally ordered
and unique, so the cross-table `id` collision never arises (both tables have their own `bigserial`,
so a naive merged cursor on `(occurred_at, id)` would have colliding tiebreakers). The work is
getting `Pagy::Keyset` to apply its predicate to a `from(subquery)` relation; the aggregate cannot
be filtered in `WHERE`.

---

### 11.3 Q3 — "All `order.submitted` events, who triggered them, by date range"

The easiest of the three: fully served by `audit_events` with no join at all, because
`actor_label` is already on the row.

```ruby
AuditEvent.where(action: "order.submitted", occurred_at: range)
          .order(occurred_at: :desc, id: :desc)
```
Index: `(action, occurred_at DESC)`.

Rollup for the same screen's header:

```ruby
AuditEvent.where(action: "order.submitted", occurred_at: range)
          .group(:actor_type, :actor_id, :actor_label)
          .order("count_all DESC")
          .count
# => { ["User", 17, "Jane Doe <jane@x.com>"] => 42, ... }
```

Because `metadata` holds the full event payload, this screen can also surface domain columns
(`total_cents`, `line_count`) without touching the `orders` table — which matters when the order
has since been deleted.

**Rendering it  [added 2026-08-28]** — `shared/_event_payload`, on every screen that lists events.
It was stored, exported by `CsvExport` and shown nowhere for a long time, because the property was
pinned one layer too low: `auditor_questions_spec`'s "surfaces domain values from metadata" asserts
on `ActionReport#events`, and passes whether or not a screen ever prints them.

The partial renders **three** states, not two. An empty `metadata` means either *this action
carried no payload* or *`Redaction` emptied it* (§13), and those are the same empty jsonb on the
row — redaction deliberately leaves no flag column, since the point is that everything else is
untouched. Rendering both as nothing turns an erasure into exactly the silent hole §13 exists to
prevent, so the redacted case is stated outright and is **not** collapsed behind a `<details>`: a
disclosure the reader has to click for has not been made. The only trace on the row is the marker
string, so `Redaction.marker?` is the discriminator, written next to `marker_for` and matched
against it in `redaction_spec` rather than re-spelled as a regex in a view.

Values render **in full**, via `audit_metadata_value` rather than `audit_value`. Truncation is
right for a diff cell in a wide table and wrong here: `metadata` is the structured evidence behind
the summary sentence — the exact `total_cents`, the whole tracking number — and an ellipsis in it
is the screen under-reporting without saying so.

**The action picker needs no query:** `Audit::Registry.keys` is the authoritative list, in memory.

---

### 11.4 Screens, summarized

| Screen | Driven by | Index | Date bound |
|---|---|---|---|
| Actor activity — "what did Jane do" | `audit_events` + `audit_changes` | `(actor_type, actor_id, occurred_at DESC)` on both | **required** |
| Record history — "everything about Order #4821" | `audit_changes` | `(record_type, record_id, occurred_at DESC)` | optional, keyset-paged |
| Record narrative — "what was *done* to Order #4821" | `audit_events` | `(subject_type, subject_id, occurred_at DESC)` | optional, keyset-paged |
| Record timeline — both layers, host-facing | `audit_changes` spine + `audit_events` | `(record_type, record_id, occurred_at DESC)` | optional, keyset-paged |
| Class activity — "all Order changes" | `audit_changes` | `(record_type, occurred_at DESC)` | **required** |
| Field filter — "who touched `status`" | `audit_changes` | GIN `(changed_columns)` | **required** |
| Action report — "all order.submitted" | `audit_events` | `(action, occurred_at DESC)` | **required** |
| Out-of-band review — `request_id IS NULL` | `audit_changes` | `(occurred_at DESC)` | **required** |

Every one of these is a single indexed range scan over a bounded set of partitions. None requires
a join to a business table, which is what keeps the screens fast *and* keeps them truthful about
deleted records.

---

### 11.4a CSV export  **[added 2026-08-28]**

Every browse screen serves `?format=csv` through `AuditLog::CsvExport`, streamed. Three decisions
in it are load-bearing:

**No row cap.** The screens page precisely so they never truncate silently; an export that quietly
stopped at 10,000 rows would put that failure straight back. The only bound is the screen's own
date range, which the caller has already applied.

**It streams.** A month of `audit_changes` is not something to build in memory as one String and
hand to `send_data`. Rows are fetched in batches and yielded as they are formatted. `Last-Modified`
is set because `Rack::ETag` digests the whole body to compute an entity tag when it has no other
validator — which would buffer the very thing the streaming avoids.

**Batching walks the same `(occurred_at, id)` keyset the screens page by, not `in_batches`.**
`in_batches` orders by primary key and discards the `ORDER BY`, so the export would come out in a
different order from the screen it was taken from. Row-value comparison keeps the caller's date
predicate intact, so partitions still prune.

The link is `?format=csv`, **not** a `.csv` path extension. Action ids contain dots, and
`/audit/actions/order.submitted.csv` is recognised as `id: "order.submitted.csv"` with no format —
the greedy `[^/]+` id constraint swallows the extension, and the screen then serves HTML for an
action that does not exist. A test asserting only the CSV header row passes against that, because a
header is emitted even for zero rows; `audit_csv_spec.rb` asserts row content for exactly this
reason.

`csv` is declared in the Gemfile rather than merely required: it stopped being a default gem in
Ruby 3.4, so `require "csv"` alone is a `LoadError`.

---

### 11.5 Completeness reconciler

Keeps the narrative layer honest about how much of the record layer it covers:

```sql
SELECT c.request_id, min(c.occurred_at) AS at, count(*) AS change_count,
       array_agg(DISTINCT c.record_type) AS types
FROM   audit_changes c
LEFT   JOIN audit_events e
       ON  e.request_id  = c.request_id
       AND e.occurred_at >= now() - interval '2 days'   -- keeps the JOIN partition-pruned
WHERE  c.occurred_at >= now() - interval '1 day'
  AND  c.request_id IS NOT NULL
  AND  e.id IS NULL
GROUP  BY c.request_id;
```

The `e.occurred_at` predicate belongs in the `ON` clause, not the `WHERE` — in the `WHERE` it would
negate the outer join, and without it the planner cannot prune `audit_events` partitions.

- **Phase 4:** run daily as a report and alert when non-empty. Each hit is a mutation path that
  needs an entry in `Audit::Registry`. The list should trend to zero.
- **Later, if it never does:** have the job insert a synthetic `audit_events` row
  (`action: "record.changed"`, summary auto-generated from `types` and `change_count`) so the
  narrative timeline becomes complete by construction. Safe to derive after the fact — the
  authoritative record is already durable in `audit_changes`.

---

### 11.6 The drill-down carries a date bound derived from the `request_id`

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

---

### 11.7 Short request ids use the TRAILING group, never a prefix

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

### 11.8 Association ids carry a display-time label  **[added 2026-08-28]**

A field-level diff is honest and unreadable. `product_id  (not set) → 51` says
exactly what the database recorded and tells an auditor nothing about what
changed. The screens now render it as:

```
product_id    (not set)  →  WID-100 — Widget, standard (id: 51)
```

**This appears to contradict §7's actor-label decision, and does not.** Actor
labels are *snapshotted* onto every audit row at write time, precisely so that
renaming or deleting a user cannot retroactively change what the log says
happened (R6) — a live join in the actor column would let today's data rewrite
yesterday's record, which auditors read as tampering.

The distinction is **replacement versus annotation**. An actor label *is* the
identity in the actor column; there is nothing else in the cell, so it has to be
the value that was true at the time. An association label sits *beside* the id
that was recorded. The stored fact never leaves the screen, so a live lookup adds
a reading of current state without altering the record of the past. That is why
the rule is absolute: **the id is never dropped**, and the screen says once, in
prose, that names are resolved at page load and ids are what was recorded.

Storing labels was considered and rejected, and not primarily on storage cost. An
*honest* stored label — one that reads as of the moment of the change — would have
to be looked up at write time, and layer 1's write path is a Postgres trigger.
That means N `SELECT`s inside `audit_row_change` on every audited INSERT and
UPDATE, with the association map expressed in SQL. The write path is the one place
in this design that must stay cheap and must never depend on the application's
object graph.

**Three decisions inside it.**

1. **Discovery is `belongs_to` reflection, never a naming convention.** This
   schema alone disproves the convention: `orders.created_by_id` de-suffixed and
   classified is `CreatedBy`, which does not exist, while the reflection carries
   `class_name: "User"`. A convention that silently mislabels a foreign key is
   worse than one that labels nothing. `config.association_targets` overrides the
   reflected map for what reflection cannot see, and `false` suppresses a column.

2. **The label chain ends in `nil`, not in `"Product #51"`.** `ActorLabel`'s chain
   must terminate in something because its column would otherwise be blank. Here
   the id renders unconditionally, so a model with no label hook must produce *no*
   label and leave the cell byte-identical to what it was before this feature
   existed. That is what makes it opt-in rather than a rendering change imposed on
   every host app. The chain is `to_audit_label`, then `to_label`, then a
   deliberately overridden `to_s` — three explicit author decisions, and
   deliberately no sniffing of a `name` or `title` column, because guessing which
   column reads as a label is how a screen ends up confidently captioning an id
   with the wrong string.

3. **Four outcomes, all distinguishable.** Resolved, *absent* (`51 (not found)` —
   the row was deleted, which on an audit screen is information), *failed*
   (`51 (label unavailable)` — the lookup broke, which is not the same as never
   having asked), and *no label configured* (the bare id, as always). Collapsing
   absent into failed, or either into unlabelled, is the same silent hole
   §11.3's payload rendering exists to avoid. `LabelResolver` distinguishes "I do
   not label this type" (`nil` from the resolver) from "I label it and none of
   those ids exist" (`{}`), because reporting the first as the second would
   announce a deletion that never happened against every id on the screen.

Cost is one primary-key lookup per record type per page, batched before the table
renders and memoized per request — nothing at process level, since a cache of host
class names in this library would go stale across a code reload. A type that
provably cannot produce a label is pruned from the class alone, with no query, so
an application that has opted nothing in pays nothing. A cache miss still resolves
on demand: warming is an optimization, and forgetting it makes a screen slower,
never wrong.

CSV export is deliberately untouched. It is the evidence artifact; the `diff`
column ships the ids that were recorded, with no display-layer decoration in it.

---

## 12. Immutability

**Decided 2026-08-27: not enforced at the database level for the initial build.** The audit tables
are append-only by convention and by the fact that no application code path writes to them except
the trigger and the event subscriber.

What we still do, because it costs nothing:

```ruby
class AuditChange < ApplicationRecord
  self.primary_key = :id

  # NOT `= true`.  [corrected 2026-08-27]
  def readonly? = persisted?
end
```
`readonly?` makes accidental `update!`/`destroy!` from application code raise
`ActiveRecord::ReadOnlyRecord`. That catches the realistic failure — a developer wiring up a form
against the wrong model — without operational cost.

> ⚠️ **It must be keyed on `persisted?`, not hardcoded `true`.**
> `ActiveRecord::Persistence#create_or_update` raises `ReadOnlyRecord` for **inserts** too, so a
> flat `def readonly? = true` breaks `Audit::EventSubscriber`'s `create!` — the whole of layer 2
> stops working. Keying on `persisted?` expresses the rule actually wanted: rows may be inserted,
> never updated or destroyed. Found the first time seeds ran.

**If a compliance requirement later demands enforcement,** the upgrade is additive and needs no
schema change:

```sql
REVOKE UPDATE, DELETE, TRUNCATE ON audit_changes, audit_events FROM app_role;
GRANT  SELECT, INSERT             ON audit_changes, audit_events TO   app_role;
```
plus a `BEFORE UPDATE OR DELETE` trigger that raises. If the app role loses `INSERT` on
`audit_changes`, `audit_row_change()` must be recreated as `SECURITY DEFINER` owned by a
privileged role — that is the only code change involved. Retention (§8) detaches whole partitions,
which is DDL and unaffected by either.

Cryptographic tamper evidence (hash chaining / daily sealing) is explicitly **not** in scope. If it
ever is, do it as a nightly sealing job, never in the trigger — an in-trigger `prev_hash` chain
forces every insert to read the previous row, serializing all writes through one hot tuple.

---

## 13. PII, redaction, and erasure

Audit rows hold old values of fields that may be personal data, which puts R7 (immutable) in direct
tension with a GDPR/CCPA erasure request.

**Implemented 2026-08-28** as `AuditLog::Redaction`, following the resolution below exactly:

- Keep the **structural** record permanently: who changed what field, on which record, when.
- Allow **value-level redaction**: replace the old/new values in `diff` for designated PII columns
  with a `"[redacted 2026-08-27 per DSR-1182]"` marker.
- Redaction is itself an audited action (`action: "audit.redaction"`) naming the request that
  authorized it. The log records that data was removed and why, which is what regulators actually
  want, rather than a silent hole.
- This is the one operation permitted to modify `audit_changes`. Even though we are not enforcing
  append-only grants (§12), keep it out of application code: a single privileged function or rake
  task, callable by name, so that "who redacted what" is itself a reviewable surface.

Design the column exclusion list (§5) to keep the highest-sensitivity fields out of the log
entirely, so redaction stays a rare event.

### What the implementation adds to the above

**Two entry points, because there are two kinds of erasure request.**
`redact_record!` handles the *subject* — the person whose data was changed — replacing values in
`diff` and clearing the matching events' `summary` and `metadata`, since an action's payload is the
likeliest place for a verbatim second copy. `redact_actor!` handles the *actor* — the person who did
things — replacing the snapshotted `actor_label` while keeping `actor_type` and `actor_id`. That is
pseudonymization rather than deletion, and it is the right answer: their activity stays attributable
and countable, the log simply stops naming them.

**`changed_columns` is never touched.** It is the structural record, and keeping it is the whole
design in one line: *"the email address was changed at 14:02 by Jane"* stays provable after the
address itself is gone.

**The narration and the redaction share a transaction.** The log can never hold a redaction nothing
accounts for, nor an account of a redaction that did not happen.

**It is deliberately not date-bounded.** Every other query in this library carries a range so the
planner can prune; this one must reach every partition, because an incomplete redaction is a
compliance failure rather than a slow screen. Run it in a maintenance window on a large log.

**The rake task takes `FIELDS=`, not `COLUMNS=`.** `COLUMNS` is a reserved shell variable holding
the terminal width, so `COLUMNS=email rake audit_log:redact` silently arrives as a number, matches
no column, and redacts nothing while reporting success. Found by running it.

Not covered in v1, and stated here rather than discovered later: an unregistered action's summary
for a subject that is not set (`subject_type`/`subject_id` nil) will not be found by
`redact_record!`. Registry entries that carry personal data in a summary should always set
`subject`.

---

## 14. Multitenancy notes

**This design assumes a single-schema, single-tenant-per-database or row-level-tenanted app.** That
is the normal case for us. NGEN-style schema-per-tenant (`ros-apartment`) is unique to that project
and is *not* the target. Documented here only so the general solution does not have to be
redesigned if it ever recurs.

### Row-level tenanting (`acts_as_tenant`) — easy

Add `tenant_id bigint` to both tables, index it leading (`(tenant_id, occurred_at DESC)`), and have
the trigger read a third GUC `app.tenant_id` alongside the other two. Roughly zero extra complexity.

### Schema-per-tenant (`ros-apartment`) — gotchas

1. **Define the trigger function once in `public`** and reference it schema-qualified
   (`EXECUTE FUNCTION public.audit_row_change(...)`). Apartment clones the template schema when
   provisioning a tenant, so a function defined per-schema means N copies to maintain and N places
   to fix a bug.
2. **New-tenant provisioning must be verified.** Triggers get cloned with the schema, but a tenant
   created from a stale template silently loses auditing. Add a post-provision check that asserts
   every audited table in the new schema has its trigger, and fail provisioning if not.
3. **`structure.sql` is mandatory anyway** (partitions), so set `Apartment.use_sql = true` and
   confirm tenant creation loads the structure dump including functions and triggers.
4. **Reconsider partitioning per tenant.** N tenants × M months of partitions on two tables gets
   large fast. If per-tenant volume is low, keep the audit tables unpartitioned inside each tenant
   schema — schema separation already bounds table size, and you get tenant isolation for free.
5. **GUCs are session-scoped and unaffected by `search_path`**, so the correlation mechanism in §6
   works unchanged.
6. **Cross-tenant audit reporting requires a UNION across schemas.** Usually unnecessary — audits
   are per-tenant — but confirm before assuming.

---

## 16. Testing strategy

The failure mode to design against is **silent under-auditing**, so tests assert coverage, not just
behavior.

> **They run on every push.**  **[added 2026-08-28]** A forcing function that runs when someone
> remembers is not one. CI executes the suite against `spec/dummy` on PostgreSQL 18, on two Ruby
> legs: the floor `required_ruby_version` claims, and the version the library is developed on. The
> floor leg is not ceremony — it was added claiming 3.2, failed on `SecureRandom.uuid_v7` being
> 3.3+, and so caught a gemspec that would have broken every correlated write in an adopting app.
>
> Three CI findings are recorded here because each was invisible on a developer machine and each
> was a real defect rather than an environment quirk: a `pg_dump` client older than the server
> refuses to dump at all (and `schema_format = :sql` puts `pg_dump` on the migration path); the raw
> second connection in `partition_lifecycle_spec` read every credential *except* the password, which
> only fails against a server that asks; and `db:prepare` seeds a database it had to create, which
> collided with a seeded user and would have quietly changed what row-counting specs measure.
>
> **A `Rails 8.0` leg is still missing**, and the gap is exactly the one the Ruby matrix closed:
> `Rails.event` does not exist there, so `AuditLog.notify`'s documented fallback path (§7) is
> untested at the floor the gemspec claims.

- **Coverage guard:** a spec that enumerates every table in the schema, subtracts an explicit
  opt-out list, and fails if any remaining table lacks an `_audit` trigger. Adding a table without
  a decision about auditing it should break the build. **[revised 2026-08-28]** Implemented as
  `AuditLog::Coverage` plus shared examples in `audit_log/rspec`, so a host app writes three lines
  instead of copying the spec, and `rake audit_log:coverage` shares the same object — the task and
  the spec cannot disagree about what counts as covered. Copying it, which the install instructions
  used to advise, is how a forcing function ends up enforcing a rule the library no longer holds.
- **Bypass-path tests:** assert that `update_all`, `delete_all`, `insert_all`, `upsert_all`, and
  `dependent: :delete_all` each produce `audit_changes` rows. These are the cases paper_trail
  misses and the entire justification for this design — they must be regression-tested.
- **Correlation (web):** one request that saves a parent plus nested children produces exactly one
  `audit_events` row and N `audit_changes` rows sharing its `request_id`.
- **Correlation (jobs)** — the highest-value test in the suite after the coverage guard, because
  the mechanism depends on framework-internal ordering (§6.4) that no amount of source-reading
  settles:
  ```ruby
  it "attributes job writes to the enqueuing user" do
    perform_enqueued_jobs do
      Current.actor = jane
      OrderFulfillmentJob.perform_later(order)
    end
    change = AuditChange.where(record_type: "Order", record_id: order.id).last
    expect(change.actor_id).to    eq(jane.id)
    expect(change.actor_label).to eq("Jane Doe <jane@x.com>")
    expect(change.request_id).not_to eq(originating_request_id)  # fresh id per execution
    expect(AuditEvent.find_by(request_id: change.request_id).caused_by_request_id)
      .to eq(originating_request_id)                             # ...but linked to its cause
  end
  ```
  Run it against the real queue adapter, not only the test adapter. Add a second case using
  `perform_all_later` to prove bulk enqueue also carries `audit_origin` (§6.4), and a third
  asserting a `config/recurring.yml` task lands as `source: "system"` with a NULL actor.
- **Job base class:** every `ApplicationJob` descendant participates; assert no job class in
  `app/jobs` inherits directly from `ActiveJob::Base`.
- **Atomicity:** a transaction that rolls back leaves zero rows in both tables.
- **Immutability:** `AuditChange.first.update!(...)` raises; the app role cannot `DELETE`.
- **No-op updates:** saving a record without changing anything writes nothing.
- **Exclusions:** touching only `updated_at` writes nothing.
- **Test DB caveat:** with `structure.sql`, the test database is loaded from the dump, so triggers
  are present. Verify this explicitly in CI once — if the test DB were ever built from `schema.rb`,
  every audit test would pass vacuously.

---

## 17. Performance validation

Measure before building the UI, on realistic hardware and data:

1. **Single-row write overhead.** p50/p99 of `UPDATE orders SET status = ...` with the trigger
   attached vs. detached. Expect a small fraction of total statement cost; investigate if it exceeds
   ~15%.
2. **Bulk write.** Time a 100k-row `insert_all` with and without the trigger. This calibrates when
   `Audit.without_logging` is warranted.
3. **Wide rows.** `to_jsonb(OLD)` cost scales with column count and width. Test against the widest
   table in the schema; if a table has large text columns, confirm the exclusion list covers them.
4. **Read paths at volume.** Load ~10M `audit_changes` rows across 12 partitions and check
   `EXPLAIN (ANALYZE, BUFFERS)` for each of the three canonical queries in §11 (on PG 18, `BUFFERS`
   is included automatically). Every plan must
   show partition pruning plus an index scan — never a `Seq Scan` on a partition, and never more
   partitions touched than the date range covers. Confirm the `changed_columns` GIN index is
   actually chosen for the field filter.
5. **Storage growth.** Bytes per audit row against projected write volume → 12- and 36-month
   forecasts. This is the input to the retention horizon (the reference app's `ROLLOUT.md` Q2).

Record the numbers in this document when they exist.

### First measurements (2026-08-27)

Reference implementation, PostgreSQL 18.6, Apple Silicon laptop, **~600k `audit_changes` rows**
across two populated monthly partitions (139 MB + 138 MB). Read paths only; item 1 (write overhead)
and item 5 forecasting still to do.

| Query | Partitions touched | Seq scan | Execution |
|---|---|---|---|
| Q1 actor activity — events, bounded | 1 | none | 0.37 ms |
| Q1 actor activity — changes, bounded | 1 | none | 0.37 ms |
| Q2 one record, **unbounded** | 6 (all) | only near-empty ones | 0.04 ms |
| Q2 whole class, bounded | 1 | none | 0.26 ms |
| Q2 field filter, bounded (GIN) | 1 | none | 0.82 ms |
| Q3 action report, bounded | 0 (pruned) | none | 0.01 ms |
| Drill-down by `request_id` | 6 (all) | only near-empty ones | 0.02 ms |

**Storage: ~484 bytes per `audit_changes` row** at this row shape (a small jsonb `diff`, a
two-element `changed_columns`, a ~40-char `actor_label`), indexes included. That is the number to
multiply by projected write volume against the retention horizon in
the reference app's `ROLLOUT.md`.

Two things the measurements confirm and one they corrected:

- **Bounded range ⇒ one partition.** Every bounded screen pruned to a single partition. Rule 1 in
  §11.0 is doing exactly what it was written to do.
- **Unbounded ⇒ every partition**, as predicted — which is why only the single-record screen is
  allowed to be unbounded, and why it is row-capped.
- **A benchmark that omits the real `ORDER BY` measures a plan the application never runs.** The
  first version of this task hand-rolled its relations and dropped `newest_first` from the field
  filter, reporting a 48 ms sequential scan for a query that in reality uses
  `(record_type, occurred_at DESC)` and returns in 0.8 ms. Drive benchmarks through the actual
  query objects. Related: only flag a sequential scan on a partition large enough for it to cost
  something — a seq scan on a nearly-empty future partition is the correct plan, and flagging it
  trains people to ignore the output.

**Tooling exists:** `bin/rails audit_log:benchmark ROWS=100000` in the reference implementation
generates volume, then runs `EXPLAIN (ANALYZE, BUFFERS)` over each canonical query and reports
partitions touched, whether any partition was sequentially scanned, execution time, and bytes per
row. Item 4 above is the one to run before the UI phase.

**A caveat about asserting plans in tests.** [added 2026-08-27] On a test database with a handful of
rows, the planner correctly prefers a sequential scan no matter how good the index is, and
`enable_seqscan = off` only proves *some* index was chosen, not the intended one — so a spec that
asserts "uses index X" either fails spuriously or asserts nothing. Split the two concerns:
assert **partition pruning** from the plan (size-independent and the thing that actually matters),
and assert **index existence and definition** against `pg_indexes` (deterministic, and the thing
that actually regresses when someone edits the install SQL). Leave plan-shape-at-volume to the
benchmark task. Note also that indexes on a partitioned parent are created on each partition under
a partition-local name (`audit_changes_2026_09_actor_idx`), so match on the shared suffix.

---

## 20. PostgreSQL version notes

**The plan targets PG 16 and requires nothing newer.** Partitioning, jsonb, GIN on `text[]`,
`set_config`, and plpgsql triggers are all long-established. What follows is what PG 18 adds, ranked
by whether it is worth anything to *this* feature.

### 20.1 Worth adopting — but not PG-18-gated

**UUIDv7 for `request_id`.** This is the single largest available win, and it does not require
PG 18 at all.

`request_id` is the correlation key, so `audit_changes (request_id)` is a B-tree index taking one
insert per row on the highest-volume table in the database. With random UUIDv4 keys, every insert
lands at a random point in the index: page splits scatter across the whole structure, WAL inflates,
and cache locality is poor. UUIDv7 is timestamp-prefixed and therefore **temporally sortable**, so
inserts concentrate at the right edge of the index the way a bigserial would.

PG 18 adds `uuidv7()` (and an explicit `uuidv4()` alias), which matters if the *database* generates
the value. Ours doesn't — the application does, one per request. Ruby 3.3+ ships
`SecureRandom.uuid_v7`, and we are on Ruby 3.4.5, so:

```ruby
Current.request_id = SecureRandom.uuid_v7
```

**works on PG 16 today**, with no extension, no round trip, and no dependency. Adopt it now; treat
PG 18's `uuidv7()` as useful only if a column default is ever wanted.

> ⚠️ **Do not use `request.request_id` as the audit correlation key.** Rails'
> `ActionDispatch::RequestId` middleware *accepts the client's `X-Request-Id` header* when present.
> That makes the value attacker-controlled: a client can replay one id across many requests to
> merge unrelated actions into a single audit event, or supply an id colliding with another user's
> action. Generate the audit correlation id server-side with `SecureRandom.uuid_v7` and keep
> `request.request_id` — if wanted at all — as a separate `metadata` field for log correlation
> only. This is an integrity bug independent of PG version, and it is the one item in this section
> to fix regardless of what the servers run.

**Explicit `VACUUM FREEZE` in the partition-rotation job.** Once a month's partition is closed it
never changes again, so freezing it deterministically is better than waiting for autovacuum. Works
on any version, and the rotation job (§8) already runs at the right moment.

### 20.2 Genuine PG 18 wins

| Feature | Why it matters here |
|---|---|
| **Eager page freezing** — *"Allow normal vacuums to freeze some pages, even though they are all-visible... This reduces the overhead of later full-relation freezing"* | The best fit of anything in PG 18. Our partitions are insert-only, so pages go all-visible and, before PG 18, *"vacuum never processed all-visible pages until freezing was required"* — deferring the entire cost into an anti-wraparound storm months later, on the largest table in the database. Tunable per-table via `vacuum_max_eager_freeze_failure_rate`; the default is well-suited to insert-only tables, so leave it alone unless a partition proves otherwise. |
| **Asynchronous I/O** — *"can improve performance of sequential scans, bitmap heap scans, vacuums"* | Hits three things we do: bitmap heap scans behind the `changed_columns` GIN index, scans of cold partitions during retention export, and vacuum of huge partitions. Set `io_method = io_uring` on Linux. Diffuse but real. |
| **`IN (VALUES ...)` → `= ANY`, and OR-clauses → arrays** | Directly improves §11.1's drill-down, which is literally `WHERE request_id IN (<50 ids>)` — the hottest query the auditor UI runs. |
| **B-tree skip scan** — *"used in more cases such as when there are no restrictions on the first or early indexed columns"* | Lets `(actor_type, actor_id, occurred_at)` serve a query filtering on `actor_id` alone, since `actor_type` has ~3 distinct values. Insurance against a forgotten index, not a reason to plan fewer of them: it does **not** replace `(record_type, occurred_at DESC)`, because skipping there means skipping over high-cardinality `record_id`. |
| **`EXPLAIN ANALYZE` includes `BUFFERS` by default** | Small quality-of-life win for the §17 validation work, which asks for exactly that output. |
| **Data checksums on by default for new clusters** | Worth noting in the compliance narrative: since we are not doing cryptographic tamper evidence (§12), storage-level corruption detection on the audit tables is the integrity guarantee we *do* have. Free on a new PG 18 cluster; on PG 16, confirm `initdb` was run with `--data-checksums`. |

### 20.3 Evaluated and rejected

**`RETURNING old.*` / `new.*`** (*"allows the RETURNING list of INSERT/UPDATE/DELETE/MERGE to
explicitly return old and new values"*). Superficially a way to capture diffs without triggers —
and exactly the wrong trade. It requires each *statement* to opt in, which reintroduces the
completeness gap that disqualified paper_trail in §3: any `update_all` or raw SQL written without
the `RETURNING` clause is silently unaudited. Triggers are chosen precisely because they cannot be
opted out of. Useful for application features, not for this.

**Virtual generated columns** (*"generate their values when the columns are read"*, now the default
in PG 18). Not applicable to `changed_columns`: virtual columns are computed at read time and
cannot be indexed, and a GIN index is the entire reason the column exists. `STORED` generated
columns have been indexable since PG 12, but generated expressions cannot contain subqueries, so
`ARRAY(SELECT jsonb_object_keys(diff))` is not expressible. Keep populating it in the trigger,
where it is one line and already correct.

**Named `NOT NULL` constraints in `pg_constraint`.** No bearing on this design.

### 20.4 Recommendation

Build against PG 16 as specified. Adopt `SecureRandom.uuid_v7` and the server-side correlation id
immediately — that is a correctness fix and a performance win at once. Treat PG 18 as a worthwhile
but non-blocking upgrade whose main payoff here is eager freezing, which becomes more valuable the
longer the retention window in Q2 turns out to be.
