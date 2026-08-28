# AuditLog

A two-layer, compliance-grade audit log for Rails 8 + PostgreSQL. Implements
[`DESIGN.md`](DESIGN.md) — the design record, which sits next to this file and is
the authority on *why* any of this is shaped the way it is.

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
| `DESIGN.md` | Why every decision here is what it is. Cited by section number from source comments. |
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

## Before you change anything

The reasoning behind every decision here lives in [`DESIGN.md`](DESIGN.md), which
is the single source of truth for it — this file does not restate it. The
sections most likely to matter, and the shape of the mistake each one prevents:

| If you are touching | Read | Because |
|---|---|---|
| `transaction_stamp.rb` | §6.1 | `begin_db_transaction` is the obvious hook and misses `update_all` — bulk writes land with a **NULL actor** |
| `current.rb`, job or controller context | §6.2, §6.4 | the origin is captured in `serialize`, not `around_enqueue`; `perform_all_later` skips enqueue callbacks entirely |
| `event_subscriber.rb`, `record.rb` | §7, §12 | `readonly?` keyed on `true` breaks **inserts**, silently disabling layer 2 |
| `partitions.rb`, the SQL, migrations | §8 | every boundary is UTC midnight, and the three manual operations must not overlap |
| a query object or a screen | §11 | mandatory date bounds are what make the screens prune |
| anything storing a timestamp | §4 | `occurred_at` is filled by a column DEFAULT so `config.time_zone` cannot reach it — supplying it from Ruby breaks that silently |

Section numbers are cited from source comments throughout the library, so they
are stable. Sections 15, 18 and 19 were project rollout and are now in
[`../../ROLLOUT.md`](../../ROLLOUT.md).

`CLAUDE.md` at the repository root carries the same decisions as a terse
"do not "fix" this" list, for agents that will not read a 1,900-line document.

## Not implemented (deliberately)

Per [`DESIGN.md`](DESIGN.md) §12, §13, and the open questions in
[`../../ROLLOUT.md`](../../ROLLOUT.md):

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
