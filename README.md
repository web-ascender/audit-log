# AuditLog

A two-layer, compliance-grade audit log for Rails 8 + PostgreSQL. Implements
[`DESIGN.md`](DESIGN.md) — the design record, which sits next to this file and is
the authority on *why* any of this is shaped the way it is.

> **Copyright (c) 2026 Web Ascender. All rights reserved.**
> **CONFIDENTIAL AND PROPRIETARY PROPERTY.** This software is for internal
> company use on company projects only. Unauthorized copying, modification, or
> distribution via the public internet or any cloud environment is strictly
> prohibited. See [`LICENSE.txt`](LICENSE.txt).
>
> The gemspec sets `allowed_push_host` to a non-host on purpose, so `gem push`
> fails instead of publishing to rubygems.org. Install from the private repo or a
> path, never from a public source.

Nothing in this gem references an application constant, an authentication gem, or
a model name — every coupling point is a lambda on `AuditLog.config`. That is
what lets one library serve every internal app without knowing anything about any
of them.

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

0. Two gems, both for the auditor UI only — layers 1 and 2 need nothing:

   ```ruby
   gem "pagy", "~> 9.3"   # keyset pagination for the screens
   gem "csv",  "~> 3.3"   # export; csv stopped being a default gem in Ruby 3.4
   ```

   Skip them only if you also drop `app/controllers`, `app/views`,
   `pagination.rb` and `csv_export.rb` — the audit machinery itself does not
   reference either.

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

6. Attach a trigger per audited table — conventionally in the migration that
   creates it, so the decision lands in the same reviewable diff as the table:

   ```ruby
   create_table :orders { |t| ... }
   attach_audit_trigger :orders, model: "Order"
   ```

   That placement is a review convention, not a requirement — see
   [Attaching to a table that already exists](#attaching-to-a-table-that-already-exists).

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

### Attaching to a table that already exists

Supported, and no different mechanically. `attach_audit_trigger` is a bare
`CREATE TRIGGER`: it reads nothing from the `create_table` beside it and carries
no state between the two calls, so a standalone migration is equivalent.

```ruby
class AuditExistingOrders < ActiveRecord::Migration[8.1]
  def up   = attach_audit_trigger(:orders, model: "Order")
  def down = detach_audit_trigger(:orders)
end
```

`coverage_spec.rb` is satisfied either way — it queries `pg_trigger`, not the
migration history.

Three things to check first. None is about *when* the trigger is attached; all
three are about the shape of the table.

- **Step 5 must already have run.** `CREATE TRIGGER` resolves
  `public.audit_row_change` at creation time, so a missing install fails the
  migration loudly. This is the harmless one.
- **The table needs a `bigint`-compatible `id`.** The trigger function assigns
  `rec_id bigint := NEW.id`, and `audit_changes.record_id` is `bigint NOT NULL`.
  A `create_table id: false` join table, a `uuid` primary key, or a primary key
  not named `id` therefore **fails on the first write after attaching**, not at
  migration time. Every table in this app is uniform, so the constraint stays
  invisible until you meet a legacy schema. Check the primary key before you
  attach.
- **`CREATE TRIGGER` takes `SHARE ROW EXCLUSIVE` on the table.** Catalog-only, no
  rewrite, so it is fast — but it blocks writes while held, and a *pending*
  request queues every write behind it. On a busy table set a `lock_timeout` and
  retry, rather than letting the migration wait behind one long transaction. Same
  reasoning as `config.maintenance_lock_timeout` for the maintenance tasks.

**What the history then looks like.** Rows that existed before the attach have no
back-history, and there is no backfill — the trigger records changes, and those
changes did not pass through it. Two things narrow the gap:

- The **first `UPDATE`** of a pre-existing row still yields a complete
  `[old, new]` pair, because the diff reads `to_jsonb(OLD)` off the live row. What
  is missing is the changes before the attach, not the values before the change.
- A **`DELETE`** snapshots the whole final row, so even a row created long before
  the trigger leaves a full record behind when it goes.

What remains is epistemic: a record with no `audit_changes` rows is ambiguous
between "never changed" and "predates the trigger". **Record the attach date** —
the migration's own timestamp is the durable answer. An audit trail that cannot
say which of the two it means is under-reporting without saying so, which is the
one failure mode this whole design exists to prevent.

### Re-attaching, and changing a table's exclusions

**`attach_audit_trigger` is not idempotent, deliberately.** A second attach on an
already-audited table fails:

```
ERROR:  trigger "orders_audit" for relation "orders" already exists   -- SQLSTATE 42710
```

`trigger_name` is `#{table}_audit` — derived from the table alone, ignoring both
`model:` and `exclude:` — so two attaches on one table *always* collide on the
name, whatever arguments they pass. That collision is load-bearing. Were the name
to incorporate the model or the exclusion list, the second attach would **succeed**
and the table would carry two triggers: two `audit_changes` rows for every write,
under possibly different exclusion sets. Double-counted audit rows are far worse
than a failed migration — invisible until somebody counts, and wrong in every
rollup and reconciliation downstream. Postgres DDL is transactional and Rails
wraps each migration, so the duplicate fails loudly with nothing half-applied.

`detach_audit_trigger` **is** idempotent (`DROP TRIGGER IF EXISTS`). The asymmetry
is the point, and it makes detach-then-attach the supported way to change a
table's exclusions or its model name — idempotent end to end:

```ruby
def up
  detach_audit_trigger :orders
  attach_audit_trigger :orders, model: "Order", exclude: %w[internal_notes]
end
```

Changing the exclusion list is not retroactive: rows already in `audit_changes`
keep the diffs they were written with. A newly excluded column stops appearing
from the re-attach forward and stays in the history before it.

`CREATE OR REPLACE TRIGGER` exists as of PostgreSQL 14 (verified on 18.6) and
would make attaching idempotent. It is deliberately not used: it would also
silently absorb a second attach carrying a *different* model name or exclusion
list, which is exactly the mistake worth hearing about. There is no
`CREATE TRIGGER IF NOT EXISTS` in PostgreSQL at all.

Re-running a migration is not how you meet this — `schema_migrations` prevents
that. The reachable paths are two branches each attaching the same table, a later
"fix" migration attaching a trigger the table already has, and a migration
attaching to a table whose trigger already arrived via `db/structure.sql` (which
carries every trigger, since `schema_format = :sql`).

### Emitting events from a controller action

Steps 5 and 6 turned layer 1 on; step 7 gave it an actor. Every row your
controllers touch is already being recorded, field by field, with no code in the
controller at all. Layer 2 is the *sentence* over the top of that — and it takes
two pieces, in two files:

| | Lives in | Does |
|---|---|---|
| `AuditLog::Registry.register` | `config/initializers/audit_log.rb` | declares the action and renders its human summary |
| `AuditLog.notify` | the controller, model or job | emits it, carrying the payload that summary reads |

**A `notify` with no registry entry is a silent no-op** — the event reaches any
observability subscriber and never becomes an `audit_events` row. That is how
analytics stays out of the audit tables (`registry.rb`), and it is also the
first thing to check when an action does not show up on `/audit`.

You never pass the actor, IP, source, timestamp or `request_id`. All five come
from `AuditLog::Current`, which `ControllerContext` populated in a
`before_action` — the payload is only the domain detail.

#### The ordinary case: create, update, destroy

```ruby
class InvoicesController < ApplicationController
  before_action :set_invoice, only: %i[update void]

  def create
    @invoice = Invoice.new(invoice_params)

    # Emit INSIDE the success branch. An event for a save that failed
    # validation is a lie the audit log cannot take back.
    if @invoice.save
      AuditLog.notify("invoice.created",
        invoice_id: @invoice.id,
        number:     @invoice.number,
        customer:   @invoice.customer.name,
        total_cents: @invoice.total_cents)
      redirect_to @invoice, notice: "Invoice created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @invoice.update(invoice_params)
      # `saved_changes` is a good payload: it says WHICH fields moved without
      # duplicating layer 1's before/after values, which audit_changes already
      # holds against this same request_id.
      AuditLog.notify("invoice.updated",
        invoice_id: @invoice.id,
        number:     @invoice.number,
        fields:     @invoice.saved_changes.keys - %w[updated_at])
      redirect_to @invoice, notice: "Invoice updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def void
    # Read anything the summary needs BEFORE the row goes away.
    number = @invoice.number

    @invoice.destroy!
    AuditLog.notify("invoice.voided",
      invoice_id: @invoice.id, number: number,
      reason: params[:reason].presence || "no reason given")
    redirect_to invoices_path, notice: "Invoice voided."
  end
end
```

The matching half, in `config/initializers/audit_log.rb`. The payload keys and
the lambda's `p[...]` reads are the contract between the two files — nothing
checks it for you, and a typo renders an empty gap in a sentence:

```ruby
AuditLog::Registry.register "invoice.created",
  description: "An invoice was raised against a customer.",
  subject: ->(p) { ["Invoice", p[:invoice_id]] },
  summary: lambda { |p|
    "Raised invoice #{p[:number]} for #{p[:customer]} — " \
      "#{ActiveSupport::NumberHelper.number_to_currency(p[:total_cents].to_i / 100.0)}"
  }

AuditLog::Registry.register "invoice.updated",
  subject: ->(p) { ["Invoice", p[:invoice_id]] },
  summary: ->(p) { "Edited invoice #{p[:number]} (#{Array(p[:fields]).join(', ')})" }

AuditLog::Registry.register "invoice.voided",
  description: "An invoice was destroyed, cascading to its line items.",
  subject: ->(p) { ["Invoice", p[:invoice_id]] },
  summary: ->(p) { "Voided invoice #{p[:number]} (#{p[:reason]})" }
```

`subject:` names the aggregate root the action was about. It is indexed
(`subject_type, subject_id, occurred_at DESC`) and it is how `redact_record!`
finds an action's rows — **an entry whose summary can carry personal data should
always set it**, or a later erasure request will not reach it (DESIGN §13). Omit
it only for an action with no single subject, such as a bulk price change.

The summary is rendered **once, at emit time**, and stored. Editing one of these
lambdas changes what future rows say, never what past rows said — a copy edit
must not alter the historical record.

#### An action that spans several writes

Put the `notify` in the model or service, inside the same transaction as the
work, and let the controller stay a controller:

```ruby
# app/controllers/invoices_controller.rb
def issue
  @invoice.issue!(by: current_user)
  redirect_to @invoice, notice: "Invoice issued."
end

# app/models/invoice.rb
def issue!(by:)
  transaction do
    update!(status: "issued", issued_at: Time.current)
    line_items.each { |item| item.update!(unit_price_cents: item.product.price_cents) }
    customer.update!(balance_cents: customer.balance_cents + total_cents)

    # One notify for the whole action, not one per row: layer 1 already wrote a
    # row per row. Inside the transaction, so a rollback discards the sentence
    # along with the changes it describes.
    AuditLog.notify("invoice.issued",
      invoice_id: id, number: number, line_count: line_items.size,
      total_cents: total_cents, approver: by.to_label)
  end
end
```

Two reasons it belongs there rather than in the controller: the same action
invoked from a console session or a rake task still gets its narrative, and the
event cannot commit without the writes it claims happened.

`approver:` is in the payload only because it may differ from the actor — the
person who clicked is already on the row. Do not re-send `current_user` as a
payload key; it is duplication that can later disagree with `actor_label`.

#### An action whose writes skip Active Record

Nothing changes. Emit the event exactly as above — layer 1 catches the rows from
the database side:

```ruby
def bulk_adjust
  percent = params[:percent].to_i.clamp(-50, 50)
  # No callbacks, no instantiation, no Active Record involvement at all.
  count = Product.where(active: true)
                 .update_all("price_cents = (price_cents * #{100 + percent}) / 100")

  AuditLog.notify("price.bulk_adjusted", percent: percent, count: count)
  redirect_to products_path, notice: "Adjusted #{count} prices."
end
```

The `audit_changes` rows and this `audit_events` row share the request's
`request_id`, so the drill-down shows the sentence with all `count` diffs
under it.

#### An action that only enqueues work

Do not emit anything for the enqueue. Once `ApplicationJob` includes
`AuditLog::JobContext` (step 8), the job inherits this request's actor and
records this request as its `caused_by_request_id`; the job emits its own event
when the work actually happens:

```ruby
def ship
  InvoiceDeliveryJob.perform_later(@invoice)
  redirect_to @invoice, notice: "Delivery queued."
end
```

An event emitted here would claim the invoice was delivered at the moment
somebody clicked a button, which is not what happened.

#### Payload rules

- **Pass primitives — ids, strings, numbers, arrays.** The payload is stored
  verbatim in the `metadata` jsonb column. Passing an Active Record object
  serialises every one of its attributes into the audit log, PII included.
- **Include what the sentence needs plus the evidence behind it**, and nothing
  else. `metadata` renders on the action screen as the structured backing for
  the summary.
- **Never put a secret, token or password in a payload.**
  `config.default_excluded_columns` keeps `encrypted_password` and the reset
  tokens out of layer 1's diffs. It does not filter a layer 2 payload — that is
  exactly what the call site passed, and nothing else inspects it.
- **Getting something back out is blunt.** `AuditLog::Redaction` empties an
  event's `metadata` wholesale and replaces its `summary` with the marker, so
  one careless key costs that subject its entire narrative. It also matches on
  `subject_type` / `subject_id`, which means an action registered without a
  `subject:` cannot be reached by a record-level erasure at all.
- **`nil` values are dropped** (`payload.compact`), so a key that is sometimes
  absent will be absent from `metadata`, not present as `null`.
- **Do not rescue around `notify`.** The engine sets
  `Rails.event.raise_on_error = true` on purpose: a failed audit write must not
  vanish while the change it described commits anyway.

#### Finding the actions you have not registered yet

Skipping a `notify` is legal — the change is still fully audited at the record
level, it just appears under the generic record view with no name on it. That is
what `bin/rails audit_log:reconcile` reports: correlated changes with no
registered action. Run it after adding controllers, and let it tell you which
narratives are still missing.

---

## Making association ids readable (optional)

A field-level diff records what the database recorded, which is an id:

```
product_id     (not set)  →  51
customer_id    (not set)  →  25
```

Define `to_audit_label` on a model and every id pointing at it gains a caption:

```ruby
class Product < ApplicationRecord
  def to_audit_label = "#{sku} — #{name}"
end
```

```
product_id     (not set)  →  WID-100 — Widget, standard (id: 51)
```

That is the whole opt-in. No configuration, no per-column declaration: `belongs_to`
reflection on the *changed* model finds which columns are foreign keys and what
they point at, and the label chain is tried in this order —

| | |
|---|---|
| `to_audit_label` | first, so a model can show auditors something other than what it shows the rest of the UI |
| `to_label` | the same hook actor labels use |
| `to_s` | only when the model deliberately overrode it |
| *nothing* | no label. The cell renders the bare id, exactly as it did before |

There is deliberately **no fallback that reads a `name` or `title` column.**
Guessing which column reads as a label is how a screen ends up confidently
captioning an id with the wrong string; `to_audit_label` is the seam for saying it
explicitly.

**The id is never replaced.** It is what the audit log actually stores, so the
label annotates it and the screen states once that names are resolved when the
page loads. This is the opposite of `actor_label.rb`, which *snapshots* its label
onto every row at write time — see DESIGN §11.8 for why both are right.

### The four things a cell can say

| | Means |
|---|---|
| `WID-100 — Widget (id: 51)` | resolved |
| `51 (not found)` | nothing with that id exists now — it was almost certainly deleted, which on an audit screen is information |
| `51 (label unavailable)` | the lookup itself failed. **Not** the same as "no label configured", and never a blank cell |
| `51` | no label available. Every screen renders exactly as it did before this feature existed |

### Configuration

Both attributes are optional and both have working defaults.

```ruby
AuditLog.configure do |config|
  # ->(type, ids) { {id => label} }  Batch: called once per record type per page.
  # Return nil for a type you do not label; {} for a type you do label none of
  # whose ids still exist. The screen renders those two differently.
  #
  # nil disables association labelling entirely.
  config.record_label_resolver = lambda do |type, ids|
    klass = type.safe_constantize
    klass ? klass.where(id: ids).index_by(&:id).transform_values(&:to_audit_label) : nil
  end

  # For the foreign keys reflection cannot see. Merged OVER the reflected map;
  # `false` suppresses a column reflection did find.
  config.association_targets = { "LineItem" => { "legacy_product_ref" => "Product" } }
end
```

**Reflection, not convention, and this is why:** `orders.created_by_id` points at
`User`. De-suffixing and classifying the column name gives `CreatedBy`, which does
not exist. The `belongs_to` carries `class_name: "User"` and gets it right.

### Two things to know before turning it on

- **Scoping is your job.** The default resolver is `where(id: ids)` with no tenant
  scope, reading live business tables on a screen an auditor is trusted with. In a
  multitenant application that reads perfectly safe and is not — scope it inside
  the lambda.
- **CSV export is untouched, deliberately.** It is the evidence artifact; the
  `diff` column ships the ids that were recorded, with no display decoration.

Cost is one primary-key lookup per record type per page, batched before the table
renders. A type that cannot produce a label is skipped with no query at all, so an
application that has opted nothing in pays nothing.

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
| `actor_label.rb` | Renders the label snapshotted onto every row, and (`display`/`linkable?`) the one definition of how a stored actor reads on a screen. |
| `record_label.rb` | The **opt-in** label chain (`to_audit_label` → `to_label` → overridden `to_s` → nothing) for the record an association id points at. Display-time only; nothing it returns is stored. |
| `migration_helpers.rb` | `attach_audit_trigger` / `detach_audit_trigger`. |
| `schema.rb` | `install!` / `uninstall!` for a migration. |
| `partitions.rb` | Partition rotation, default-partition drain, yearly rollup, retention, freezing, UTC-boundary enforcement. |
| `bypass.rb` | The one escape hatch, which logs itself. |
| `redaction.rb` | The **only** thing allowed to modify audit rows. Values go, structure stays. |
| `archive.rb` | Retired partitions → gzipped CSV + manifest; drops only what verifies. |
| `pagination.rb` | Keyset paging for the screens. No page numbers, no counts. |
| `csv_export.rb` | Streaming CSV for the screens. No row cap. |
| `engine.rb` | Initializers: the adapter prepend, the event subscriber, `PGTZ`. |
| `console.rb` | Narrates console sessions. |
| `db/sql/audit_tables.sql` | The two partitioned tables and their indexes. |
| `db/sql/audit_row_change.sql` | The trigger function. The heart of layer 1. |
| `app/queries/` | One object per auditor question (`ActorActivity`, `RecordHistory`, `ActionReport`, `Reconciler`), plus `LabelResolver` — the per-request association-label cache. |
| `app/controllers/`, `app/views/` | The auditor UI. `shared/_event_payload` renders `audit_events.metadata` in three states — present, absent, redacted. |
| `DESIGN.md` | Why every decision here is what it is. Cited by section number from source comments. |
| `tasks/audit_log.rake` | `partitions`, `drain_default`, `rollup`, `retention`, `export`, `drop_exported`, `freeze`, `redact`, `reconcile`, `coverage`, `benchmark`. |

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
| `pagination.rb` or a screen's scope | §11.0 | the cursor must carry microseconds, or rows vanish between pages — and a `.limit` below the controller is a silent truncation |
| `csv_export.rb` | §11.4a | an export with a row cap reintroduces exactly what the paging removed |
| `redaction.rb` | §13 | `changed_columns` must survive; it is what keeps "the email changed at 14:02" provable |
| `redaction.rb`'s marker, `shared/_event_payload` | §11.3, §13 | a redacted payload and an absent one are the same empty jsonb — the marker is the only trace, and a screen that cannot tell them apart renders an erasure as an absence |
| `archive.rb` | §8 | `drop_exported!` may never drop a partition whose manifest does not verify |
| `actor_label.rb`, an actor cell on a screen | §6.2 | a `GROUP BY` rollup has a tuple, not a record — a hand-rolled fallback chain drops the nil branch and `actor_path(nil)` 500s the screen |
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
- **Read-access logging.** Explicitly out of scope — this records changes, not
  views.
- **Signed-PDF export.** CSV is implemented; PDF was judged unnecessary. Revisit
  only if a compliance regime asks for it.

Note the interaction between the first item and `redaction.rb`: append-only
grants would now have to carve out an exception for the one operation that is
*supposed* to modify audit rows.

Two things that used to be on this list are now built — **export of retired
partitions** (`archive.rb`, `rake audit_log:export`) and **PII redaction**
(`redaction.rb`, `rake audit_log:redact`). What remains open about redaction is
policy, not mechanism: who may authorize one, and what makes a `REASON` valid.
