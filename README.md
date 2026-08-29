# AuditLog

[![CI](https://github.com/web-ascender/audit-log/actions/workflows/ci.yml/badge.svg)](https://github.com/web-ascender/audit-log/actions/workflows/ci.yml)

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

## Getting started, end to end

An existing Rails app with existing models. Five steps, three of them generators.

```bash
# 1. Add the gem, then install: initializer, schema migration, integration
#    points, the auditor UI at /audit, the coverage spec.
bin/rails generate audit_log:install

# 2. One line per audited table. Which tables deserve auditing is a judgement
#    about your domain, so nothing can infer it.
bin/rails generate audit_log:trigger orders   --model=Order
bin/rails generate audit_log:trigger products --model=Product
bin/rails db:migrate

# 3. Prove nothing escaped the decision. Fails until every table is either
#    audited or listed in config.unaudited_tables with a written reason.
bin/rails audit_log:coverage

# 4. Name the actions worth a sentence, in config/initializers/audit_log.rb,
#    and call AuditLog.notify from the code that performs them. Optional --
#    every change is already recorded without this; the registry is what makes
#    the log readable rather than merely complete.

# 5. Give your own pages an activity history. Takes any number of models.
bin/rails generate audit_log:activity Order Product LineItem
```

Then edit `RecordActivity#audit_activity_visible?` — the generator prints this in
red, because it denies everyone until you do.

**Later, when a new model needs one:**

```bash
bin/rails generate audit_log:activity Invoice
```

The second run adds `Invoice` to the allowlist and wires up its show page. Every
file already generated is left alone.

### The generators

| | Does | Run it |
|---|---|---|
| `audit_log:install` | initializer, schema migration, `ControllerContext` and `JobContext` includes, mounts the engine, coverage spec | once |
| `audit_log:trigger TABLE --model=Model` | a migration with one `attach_audit_trigger` line | once per audited table |
| `audit_log:activity Model [Model...]` | controller, concern, helper, views, route, locale, stylesheet — and wires each model's show page | once, then again per new model |

`audit_log:activity` takes **any number of models in one call**, and calling it
again later is how you add more. Both reach the same place:

```bash
bin/rails generate audit_log:activity Order Product LineItem
# ...is equivalent to:
bin/rails generate audit_log:activity Order
bin/rails generate audit_log:activity Product LineItem
```

A model with no show page — `LineItem` usually — is still added to the allowlist
and still readable at `/activity/LineItem/86`; the generator just reports that it
could not find `line_items_controller.rb` and prints the two lines for when you
do have one. **The allowlist and the show-page wiring are independent**, which is
right: a child record often has a history worth reading and no page of its own.

Options: `--css=plain|tailwind|bootstrap`, `--path=activity`,
`--skip-show-pages`, `--skip-views`, `--skip-css`, `--skip-locale`,
`--skip-routes`, and `--force` to re-baseline generated files against the current
templates.

---

## Installing into a Rails 8 app

```ruby
# Gemfile
gem "audit_log", git: "https://github.com/web-ascender/audit-log"
```

A private repo, so `bundle` needs credentials for the company GitHub org. For
local co-development against the reference app, use a path instead:
`gem "audit_log", path: "../audit-log"`.

`pagy` and `csv` come with it. Both are for the auditor UI only — layers 1 and 2
reference neither — but they are hard dependencies rather than optional ones,
because `pagy` is load-bearing for *correctness*: `AuditLog::Pagination` is keyset
paging, and offset paging on a newest-first view of an append-only table
duplicates rows across a page boundary after a single concurrent write. See
[DESIGN §11.0 Rule 2](DESIGN.md).

### Requirements

| | | Why it is a floor and not a preference |
|---|---|---|
| Ruby | **>= 3.3** | `SecureRandom.uuid_v7`, which is `Context.new_request_id`. On 3.2 every correlated write raises. UUIDv7 gives the `audit_changes(request_id)` index insert locality, and its embedded timestamp is what bounds the drill-down. DESIGN §2.1. |
| Rails | **`~> 8.0`** | 8.0 floor for `Rails.event` (with a fallback); ceiling below 9.0 because `TransactionStamp` prepends the *private* `raw_execute`. DESIGN §2.2. |
| PostgreSQL | **18** | Layer 1 *is* a plpgsql trigger writing jsonb into range-partitioned tables. Not swappable for another database. DESIGN §20. |

`pg` is deliberately *not* a dependency, so your app picks its own build.

Ruby **3.3.0 exactly** is unusable with Rails 8.1, for a reason unrelated to this
gem: actionview 8.1.3.1 contains `yield(*, **)` inside a block, which 3.3.0's
parser rejects, while Rails still declares `>= 3.2.0`. Any later 3.3 patch is fine.

### Then run the generator

```bash
bin/rails generate audit_log:install
```

Which does steps 1–7 below. **Read the list anyway.** The generator reports what
it could not do, two of the steps are irreducibly manual, and one thing it does
needs your eyes on it.

Options: `--mount-at=/audit`, and `--skip-migration`, `--skip-routes`,
`--skip-controller`, `--skip-job`, `--skip-spec`. Re-running is safe — every step
detects work already done and reports `skip` rather than injecting twice.

**The one thing to check afterwards.** `AuditLog::ControllerContext` is
`included do before_action :set_audit_context end`, so *where* the include sits in
`ApplicationController` decides callback order. Ahead of your authentication, it
reads a `current_user` that is not resolved yet — and **every audit row in the
application gets a NULL actor, silently.** The generator lands it after the last
`before_action` it can find and then asks you to confirm; there is no way for it
to be certain, so confirm.

1. **`config.active_record.schema_format = :sql`** in `config/application.rb`.
   REQUIRED, and required before your first migration: `schema.rb` cannot
   represent partitioned tables, trigger functions, or triggers.

   The generator will **not** flip this silently on an app that already has a
   `db/schema.rb` — switching an established app is disruptive, so it tells you
   and stops.

2. **`config/initializers/audit_log.rb`** — the coupling points, and the registry
   of auditable actions. Every one is a lambda; this is the only file that knows
   anything about your app. The generator writes a commented starting point.

3. **A migration** installing the schema:

   ```ruby
   class InstallAuditLog < ActiveRecord::Migration[8.1]
     def up   = AuditLog::Schema.install!(connection)
     def down = AuditLog::Schema.uninstall!(connection)
   end
   ```

4. **`ApplicationController`: `include AuditLog::ControllerContext`**, after
   whatever establishes `current_user`. This is the entire web-side integration.

5. **`ApplicationJob`: `include AuditLog::JobContext`.** The entire job-side
   integration.

6. **`config/routes.rb`: `mount AuditLog::Engine => "/audit", as: :audit`.**
   Gate it — `config.authorize` defaults to a no-op, which is right for a demo
   and wrong for anything else.

7. **A coverage spec**, three lines, using the shared example the gem ships:

   ```ruby
   # spec/audit_log/coverage_spec.rb
   require "rails_helper"
   require "audit_log/rspec"

   RSpec.describe "audit trigger coverage" do
     it_behaves_like "an app with complete audit coverage"
   end
   ```

   This is the forcing function: a table that is neither audited nor exempted with
   a written reason fails the build. Do not weaken it to make a build pass. It
   shares `AuditLog::Coverage` with `rake audit_log:coverage`, so the spec and the
   task cannot disagree about what counts as covered.

### The two manual steps

8. **Attach a trigger per audited table.** One line per table, and the entire
   per-model cost of the design:

   ```ruby
   create_table :orders { |t| ... }
   attach_audit_trigger :orders, model: "Order"
   ```

   For a table that already exists:

   ```bash
   bin/rails generate audit_log:trigger orders --model=Order
   bin/rails generate audit_log:trigger orders --model=Order --exclude=internal_notes --replace
   ```

   `--replace` generates detach-then-attach, which is the supported way to
   *change* a table's model or exclusion list: attach is deliberately not
   idempotent, so a plain second attach fails with `42710` rather than letting two
   triggers coexist and double-write under different exclusion sets. It is not
   retroactive — rows already written keep the diffs they were written with.

   The generator warns about, and **cannot check**, the one hard constraint: the
   trigger assigns `rec_id bigint := NEW.id`, so an `id: false` join table, a
   `uuid` primary key or a primary key not named `id` **fails on the first write
   after attaching**, not at migration time. It has no connection to your table.

   Placing the attach beside `create_table` is a review convention, not a
   requirement — see
   [Attaching to a table that already exists](#attaching-to-a-table-that-already-exists).

   Nobody can generate the *decision* for you: which tables are worth auditing is
   a judgement about your domain. Step 7 is what stops it being skipped instead of
   made.

9. **Schedule `AuditLog::Partitions.ensure!` daily** (or
   `rake audit_log:partitions`). **A missing future partition is a write-path
   outage**, not a degraded report. Nothing else in `partitions.rb` belongs in a
   cron — see [The partition lifecycle](#the-partition-lifecycle).

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

## Reading one record's history

Three tabs on `/audit/records/:record_type/:record_id/history`. The first two are
one per layer, because they answer different questions and neither substitutes
for the other; the third puts them together.

**Changes** (the default) is `audit_changes` — every INSERT, UPDATE and DELETE
against this record, field by field, complete regardless of how the write was
issued. This is the compliance-grade answer and the reason it is the landing tab.

**Actions** is `audit_events` — the same history as sentences. It has two
sections, and the split is deliberate:

- **The actions that named this record as their `subject`.** Served by
  `(subject_type, subject_id, occurred_at DESC)`, keyset-paged, uncapped. Complete
  for actions that have a `Registry` entry *and* a `subject:` lambda.
- **"Also touched this record"** — actions that wrote to it under a different
  subject or none at all: a bulk update, a save whose subject was the parent, an
  entry registered with no `subject:`. There is no column linking these to the
  record, so they are found by matching `request_id` against the record's own
  change rows.

The second section is **capped and says so**: it reads a bounded number of the
record's most recent change rows, prints how many it read, and offers `?scan=` to
widen it. That is the same treatment the request drill-down gives its date window
— a narrowed query must never be mistaken for a complete one.

**Timeline** is both layers interleaved, at the grain a person reads: one
*activity* per unit of work rather than one row per audit row, so a save that
wrote this record and forty children is one card and not forty. It is rendered
entirely from `AuditLog::Timeline`'s value objects — the same published contract
described in the next section — so the auditor UI cannot drift from what a host
app gets. `?days=` bounds it; unbounded is the default.

Both sections are reachable as query objects if you would rather build your own
view than link to the engine's:

```ruby
timeline = AuditLog::RecordTimeline.new(record_type: "Order", record_id: order.id)

timeline.events                    # subject-matched, ordered, UNLIMITED — you paginate
timeline.changes_for(page_of_events)  # the change rows behind a page, grouped by request_id
timeline.correlated(limit: 50)     # .events, .scanned, .truncated? — render all three
```

`events` returns an unlimited relation on purpose: a limit applied below the
controller is invisible to the screen rendering it. If you cap it, say so on the
page. And if you render `correlated`, render `scanned` and `truncated?` with it —
a "recent activity" list that quietly stops short is worse than no list.

> The engine sets `isolate_namespace`, so its helpers and route helpers are not
> available in your own views. Reuse the query objects, not the partials — write
> the markup that matches your app, or link to the engine screen.

---

## Building an activity history in your own app

The auditor UI is for auditors. For an *"activity history"* on your own
`orders/show`, in your own markup, use `AuditLog::Timeline` — a paginated list of
**units of work**, each one carrying its narrative, that record's field changes,
and the other records the same action touched.

```ruby
class OrdersController < ApplicationController
  include AuditLog::Pagination      # the gem's keyset pager — see below

  def show
    @order      = Order.find(params[:id])
    timeline    = AuditLog::Timeline.for(@order)
    @pagy       = paginate(timeline.activity_keys, limit: 20)
    @activities = timeline.activities(@pagy.records)
  end
end
```

`AuditLog::Timeline.new(record_type:, record_id:)` is the same thing without a
record in hand — which is what you want for a **deleted** record, since an audit
trail outlives what it describes and that is exactly when somebody reads it.

### Use `AuditLog::Pagination`, do not hand-roll one

`include AuditLog::Pagination` gives you `paginate(scope, limit:)`, reading the
cursor from `params[:page]`. It is not a convenience.

Pagy serialises the keyset cursor with `to_json`, and ActiveSupport renders a
`Time` at **millisecond** precision — while `occurred_at` is `clock_timestamp()`,
which is **microseconds**. A pager that does not override that mints a cursor
naming an instant just before the row it came from, and the next page's
`occurred_at < cursor` skips everything in the gap. **Rows vanish between pages,
silently.** It presents as a rare flake, not as an error; it took roughly one
full-suite run in eight to surface here before it was fixed.

`AuditLog::Pagination::FULL_PRECISION` is the fix, and including the module is
how you get it. It also falls back to the first page on a cursor minted for a
different screen, rather than raising or — worse — applying it and dropping rows.

```erb
<% @activities.each do |activity| %>
  <li>
    <time><%= l activity.occurred_at, format: :short %></time>

    <%# A registered action stored this sentence at emit time. nil when none did. %>
    <% if activity.headline %>
      <%= activity.headline %>
    <% else %>
      <%= t(".#{activity.operations.first}", model: Order.model_name.human) %>
      <%= activity.changed_columns.map { |c| Order.human_attribute_name(c) }.to_sentence %>
    <% end %>

    <span><%= activity.actor.display %></span>

    <% activity.field_changes.each do |fc| %>
      <div><%= fc.column %>: <%= fc.from %> → <%= fc.to %></div>
    <% end %>

    <% if activity.also_touched.any? %>
      <details>
        <summary><%= activity.also_touched.size %> other records</summary>
        <% activity.also_touched.each do |touched| %>
          <div><%= link_to touched.to_s, touched.url || "#" %></div>
        <% end %>
      </details>
    <% end %>
  </li>
<% end %>
```

### Why objects and not relations

The auditor screens encode rules that are invisible from outside the gem: a diff
value's three nil shapes mean different things, a nil actor renders "System" but
is never *stored* that way, a redacted payload and an absent one are the same
empty jsonb, an association label annotates a recorded id and must never replace
it. Handed a relation, every app re-derives those and some get them wrong on a
screen that looks fine. The value objects make each one a method call.

| Object | Reads |
|---|---|
| `Activity` | `kind` (`:narrative` / `:change_only`), `headline`, `action`, `source`, `actor`, `occurred_at`, `operations`, `changed_columns`, `field_changes`, `also_touched`, `metadata`, `redacted?`, `out_of_band?` |
| `FieldChange` | `column`, `from`, `to`, `cleared?`, `set?`, `from_label` / `to_label`, `association?` |
| `TouchedRecord` | `type`, `id`, `identifier`, `label`, `label_failed?`, `operations`, `columns`, `url`, `to_s` |
| `Actor` | `type`, `id`, `label`, `display`, `system?`, `linkable?`, `url` |

`Activity`, `FieldChange`, `TouchedRecord` and `Actor` each have `as_json`, so a
JSON API or a JS frontend gets the same contract.

**Why two calls, and two types.** `activity_keys` is an ActiveRecord relation of
`Timeline::ActivityKey` — the *identity* of each activity (which unit of work,
and when), and nothing else. It is an opaque handle: paginate it, hand the page
straight back, never render it. `activities` turns that page into
`Timeline::Activity` objects, loading the events, change rows and labels for the
whole page in three queries rather than three per row.

They are separate because Pagy needs a *relation* to build a cursor from, because
hydration has to be batched, and because the limit belongs above the controller
where you can see it (DESIGN §11.0 Rule 2) — so the library cannot paginate and
load in one call.

### Four things to know

**`headline` is nil when no registered action covered the write, and the library
will not invent one.** A sentence composed from column names would be *this
gem's* phrasing rather than yours, would re-render differently after a gem
upgrade, and on the page would be indistinguishable from a `summary` that was
frozen at emit time. You have i18n and know what your models are called — and if
they are STI, names this gem could never guess. `kind` tells you which you are
holding. Register more actions and more entries become `:narrative`.

**Never drop the id from a `TouchedRecord`.** `to_s` renders
`Grommet 10mm (Product #51)` on purpose: the label is resolved *live* from the
record's current row, the id is what the log recorded. Showing only the label
lets a rename rewrite what your timeline says happened.

**Set `config.record_url` if you want links.** It is nil by default and that is
not a placeholder — this gem does not know your routes, and it will not guess
`product_path` from `"Product"`. Return nil for a type you have no page for.

```ruby
config.record_url = lambda do |type, id|
  case type
  when "Order"   then Rails.application.routes.url_helpers.order_path(id)
  when "Product" then Rails.application.routes.url_helpers.product_path(id)
  end
end
```

**Authorization is yours.** The timeline exposes everything the log holds —
diffs, actors, other customers' records touched by the same action. That is a
staff-grade view. `config.authorize` gates the *auditor UI*; this is your screen,
so gate it with your own policy layer.

### Bounding it

`range:` narrows both halves of the union and is the biggest lever on cost.
Measured against a 36-month horizon (72 monthly partitions across the two
tables):

| Bound | Partitions touched |
|---|---|
| unbounded (default) | 72 |
| `range: 1.year.ago..Time.current` | 34 |
| `range: 90.days.ago..Time.current` | 16 |
| `range: 30.days.ago..Time.current` | 4 |

```ruby
AuditLog::Timeline.for(@order, range: 90.days.ago..Time.current)   # max age
AuditLog::Timeline.for(@order, range: (cutoff - 1.year)..cutoff)   # up to a date
```

**Close the range at the top, even when the top is "now."** `30.days.ago..`
touches 12 partitions; `30.days.ago..Time.current` touches 4, for the same span.
An endless range cannot exclude the months-ahead partitions or the default one.
(If you pass an endless range anyway, the library closes it at the current
instant for you — `occurred_at` is written by `clock_timestamp()`, so no row can
be future-dated.)

**Pass Ruby times, not SQL.** ActiveRecord binds a `Range` as literal timestamps,
which prune at *plan* time. A SQL expression like `now() - interval '30 days'`
defers pruning to run time, after the planner has already opened every partition.

**The default is unbounded on purpose**, and there is no config-level default: a
bound nobody asked for is invisible truncation. If you do bound it, **say so** —
`bounded?` and `scope_description` are there for exactly that, and they are in
`as_json` too:

```erb
<p>Showing <%= timeline.scope_description %>.</p>
```

`older_than_window?` answers "is there history before this window" with one
indexed check per table — the difference between *"end of results"* and *"end of
the window"*. It is **opt-in and never called for you**, because it deliberately
looks below the bound; calling it on every page gives back the pruning you just
bought. Call it once, at the bottom of the last page.

### What the timeline covers

The index is a union, so an entry appears if the unit of work either **wrote**
this record or was **about** it (an `audit_events` row whose `subject` is this
record). That second half is what catches an action that wrote only children, one
whose write landed in another table, one that wrote nothing at all, and every
action on a record whose table is in `unaudited_tables`.

The one thing it does not reach is an **unregistered** action that only wrote
children — no event, and no change row here. That is a registry gap rather than a
query one, and `bin/rails audit_log:reconcile` is what reports it. DESIGN §11.2b
explains why chasing it through a child's foreign key would break more than it
fixes.

The engine's own **Timeline** tab is rendered from these same objects, so the
contract cannot drift from what the auditor UI does.

### Generate it

You do not have to write any of the above by hand:

```bash
rails generate audit_log:activity Order Product Customer
```

**Any number of models, in one call or several.** That produces a controller, a
concern, a helper, three views, a route, a locale file and a stylesheet — the
reference app's implementation, extracted into templates. It is **yours**: plain
Rails, no gem-side indirection, never re-generated or upgraded later.

| | |
|---|---|
| `--css=plain` (default) | ships `audit_log_activity.css`, no framework needed |
| `--css=tailwind` | Tailwind utility classes in the markup, no stylesheet |
| `--css=bootstrap` | Bootstrap classes in the markup, no stylesheet |

The markup **structure is identical** across all three — only `class=` changes,
so switching later is rewriting strings rather than re-deriving the view. Neither
framework option installs anything; both assume you already have it working.

**It denies everyone until you edit one method.**
`RecordActivity#audit_activity_visible?` is generated as `false`, and the
generator says so in red. That default is deliberate: `Timeline` exposes previous
values of every audited column and the other records each action touched — which
on a shared action can be another customer's row. Defaulting to visible would
publish all of it to every signed-in user of an app whose roles this gem cannot
see, and nothing would report it.

The models you name become `ActivityController::VIEWABLE`, an allowlist checked
**before** `constantize` — `/activity/User/1` is a URL anyone can type. The
generator refuses to run without them rather than emitting an empty one.

**It wires up each model's show page too**, where it safely can: the
`recent_activity` call into `#show`, and the render into the view. Where it
can't — no `def show`, an ivar it cannot infer, a namespaced model — it declines
and prints the two exact lines for that model rather than guessing. Guessing
`@order` when the controller calls it `@sales_order` produces a page that renders
an *empty feed* and reports nothing, which reads as the audit log having no data.
`--skip-show-pages` opts out.

**Adding a model later is the same command again:**

```bash
rails generate audit_log:activity Invoice Shipment
```

That second run adds both to the allowlist, wires up their show pages, and
**leaves every generated file alone** — they are yours the moment they land, and
a generator that quietly reverses an edited authorization rule is worse than no
generator. `--force` re-baselines everything against the current templates when
you actually want that.

### A worked example

The reference app renders this on its order, product and customer pages, and on
a paginated history of its own at `/activity/:record_type/:record_id` — its own
markup, its own i18n for the sentence this library refuses to invent, its own
`record_url` lambda, its own role check. Nothing but the contract above:

| | |
|---|---|
| `app/controllers/concerns/record_activity.rb` | the show-page widget: the cap, the extra key that discloses it, the role check |
| `app/controllers/activity_controller.rb` | the paginated page: a record-type allowlist, `?days=`, and `include AuditLog::Pagination` |
| `app/helpers/activity_helper.rb` | the sentence, the actor, the touched records, the three nil shapes |
| `app/views/shared/_activity_feed.html.erb` | how one activity renders, deliberately not this engine's markup |
| `config/locales/en.yml` | `activity.created` / `updated` / `deleted` |

That app also shows the shape worth copying: a **manager** reads one record's
history there without holding the auditor role, because the split from `/audit`
is by *scope* — one record, an allowlist of types — and not by fidelity. Same
value objects, same detail.

Worth reading `activity_value` there before writing your own: it must return
exactly one element, because the field list is a CSS grid whose `<li>` is
`display: contents`. Returning a label and its id as two elements gives valid
markup, correct values and a scrambled page — the kind of thing only rendering
finds.

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
| `lib/audit_log/configuration.rb` | Every host-app coupling point. The only file to read before adopting. |
| `lib/audit_log/current.rb` | `CurrentAttributes` holding the audit identity as **primitives**. |
| `lib/audit_log/context.rb` | Writes the correlation GUCs onto a connection; mints UUIDv7 ids. |
| `lib/audit_log/transaction_stamp.rb` | Adapter prepend. Read the comment — it explains why `raw_execute` and not `begin_db_transaction`. |
| `lib/audit_log/controller_context.rb` | The whole web integration. |
| `lib/audit_log/job_context.rb` | The whole background-job integration. |
| `lib/audit_log/registry.rb` | The allowlist of auditable actions, and each one's human sentence. |
| `lib/audit_log/event_subscriber.rb` | `Rails.event` → `audit_events`. |
| `lib/audit_log/actor_label.rb` | Renders the label snapshotted onto every row, and (`display`/`linkable?`) the one definition of how a stored actor reads on a screen. |
| `lib/audit_log/record_label.rb` | The **opt-in** label chain (`to_audit_label` → `to_label` → overridden `to_s` → nothing) for the record an association id points at. Display-time only; nothing it returns is stored. |
| `lib/audit_log/migration_helpers.rb` | `attach_audit_trigger` / `detach_audit_trigger`. |
| `lib/audit_log/schema.rb` | `install!` / `uninstall!` for a migration. |
| `lib/audit_log/partitions.rb` | Partition rotation, default-partition drain, yearly rollup, retention, freezing, UTC-boundary enforcement. |
| `lib/audit_log/bypass.rb` | The one escape hatch, which logs itself. |
| `lib/audit_log/redaction.rb` | The **only** thing allowed to modify audit rows. Values go, structure stays. |
| `lib/audit_log/archive.rb` | Retired partitions → gzipped CSV + manifest; drops only what verifies. |
| `lib/audit_log/pagination.rb` | Keyset paging, for the auditor screens **and for host apps** — `include AuditLog::Pagination`. No page numbers, no counts, and a microsecond cursor. |
| `lib/audit_log/csv_export.rb` | Streaming CSV for the screens. No row cap. |
| `lib/audit_log/engine.rb` | Initializers: the adapter prepend, the event subscriber, `PGTZ`. |
| `lib/audit_log/console.rb` | Narrates console sessions. |
| `db/sql/audit_tables.sql` | The two partitioned tables and their indexes. |
| `db/sql/audit_row_change.sql` | The trigger function. The heart of layer 1. |
| `app/queries/` | One object per auditor question (`ActorActivity`, `RecordHistory`, `RecordTimeline`, `ActionReport`, `Reconciler`, `Coverage`), plus `LabelResolver` — the per-request association-label cache. |
| `app/queries/audit_log/timeline.rb` | The **host-facing** contract: one record's history as units of work, for an activity history in your own app. |
| `app/queries/audit_log/timeline/` | Its value objects — `Activity` (one thing that happened, loaded), `ActivityKey` (its identity before loading), `FieldChange`, `TouchedRecord`, `Actor`. |
| `app/controllers/`, `app/views/` | The auditor UI. `shared/_event_payload` and `records/_timeline_activities` both render `audit_events.metadata` in three states — present, absent, redacted. |
| `lib/audit_log/rspec.rb` | Shared examples a host app uses instead of copying a spec. Not loaded by `lib/audit_log.rb` — rspec is the host's test dependency. |
| `lib/generators/audit_log/` | `audit_log:install` and `audit_log:trigger`, with templates. |
| `DESIGN.md` | Why every decision here is what it is. Cited by section number from source comments. |
| `lib/audit_log/tasks/audit_log.rake` | `partitions`, `drain_default`, `rollup`, `retention`, `export`, `drop_exported`, `freeze`, `redact`, `reconcile`, `coverage`, `benchmark`. |

---

## Working on the library: what reloads and what does not

The gem loads its own files two ways, and only one of them reloads in a host
app's development environment:

| Path | Loader | Reloads? |
|---|---|---|
| `app/**` (queries, models, controllers, helpers, views) | Zeitwerk, via the engine | **yes** |
| `lib/audit_log/*.rb` (`configuration`, `context`, `partitions`, `schema`, …) | `Kernel#autoload`, from `lib/audit_log.rb` | **no** — once per process |

**Editing anything directly under `lib/audit_log/` requires a server restart.**
This matters in practice when you consume the gem by path, as the reference app
does: an `app/**` edit shows up on the next request, a `lib/**` edit does not.

It is deliberate rather than an oversight. `TransactionStamp` is `prepend`ed into
the Postgres adapter at boot, which reloading would corrupt, and `AuditLog.config`
memoizes its instance in `@config` on the module — so a reloaded `Configuration`
class would not replace the object already built.

The failure mode is a half-updated library: a reloaded query object calling a
stale `Configuration`. Adding a `config` attribute and using it in the same edit
raises `NoMethodError` on the next request, which is the *good* case — if the
calling code tolerates `nil`, the same staleness silently changes behaviour
instead. Restart after touching the top level.

Two path constants, both deliberate:

- **`AuditLog::GEM_ROOT`** — the gem root. `Schema::SQL_DIR` resolves `db/sql`
  against it rather than against `Engine.root`, because `Schema.install!` runs
  from a migration and a migration must not depend on a booted engine.
- **`Engine.find_root` does not exist, on purpose.** It used to, while this
  library lived inside a host app's `lib/`, where Rails' default root-walk would
  have resolved to the *host* app's root and pulled in its `app/` directories. A
  gem root is unambiguous. Do not reintroduce it.

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
| `timeline.rb` or its value objects | §11.2b | it is a PUBLISHED contract host apps render — `headline` returning nil rather than a generated sentence is part of it, and so is the two-type split |
| `record_timeline.rb`, the record screen | §11.2a | `where.not(subject_type:, subject_id:)` is NULL-unsafe and silently drops every event with no subject — which is the exact population the correlated section exists to show |
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
