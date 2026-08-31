> **Copyright (c) 2026 Web Ascender. All rights reserved.**
> **CONFIDENTIAL AND PROPRIETARY PROPERTY.** This software is for internal
> company use on company projects only. Unauthorized copying, modification, or
> distribution via the public internet or any cloud environment is strictly
> prohibited. See [`LICENSE.txt`](LICENSE.txt).

# AuditLog

[![CI](https://github.com/web-ascender/audit-log/actions/workflows/ci.yml/badge.svg)](https://github.com/web-ascender/audit-log/actions/workflows/ci.yml)

A two-layer, compliance-grade audit log for Rails 8 + PostgreSQL. Implements
[`DESIGN.md`](DESIGN.md) — the design record, which sits next to this file and is
the authority on *why* any of this is shaped the way it is.

## Contents

- [Summary](#summary)
- [Requirements](#requirements)
- [The two layers](#the-two-layers)
- [Demo Rails App](#demo-rails-app)
- [Getting started](#getting-started)
  - [1. Add the gem](#1-add-the-gem)
  - [2. Install](#2-install)
  - [3. Attach a trigger to each audited table](#3-attach-a-trigger-to-each-audited-table)
  - [4. Prove nothing was missed](#4-prove-nothing-was-missed)
  - [5. Schedule the daily task](#5-schedule-the-daily-task)
  - [6. Read the initializer before deploying](#6-read-the-initializer-before-deploying)
  - [7. Recommended: Register and emit events for significant business actions](#7-recommended-register-and-emit-events-for-significant-business-actions)
  - [8. Optional: Put a history on your own pages](#8-optional-put-a-history-on-your-own-pages)
  - [What the generator wrote](#what-the-generator-wrote)
  - [What a model needs](#what-a-model-needs)
- [Registering and emitting events](#registering-and-emitting-events)
  - [Registering actions](#registering-actions)
  - [Emitting it: create, update, destroy](#emitting-it-create-update-destroy)
  - [An action that spans several writes](#an-action-that-spans-several-writes)
  - [Letting `audited` open the transaction](#letting-audited-open-the-transaction)
  - [An action whose writes skip Active Record](#an-action-whose-writes-skip-active-record)
  - [An action that only enqueues work](#an-action-that-only-enqueues-work)
  - [Payload rules](#payload-rules)
  - [Declaring a payload contract](#declaring-a-payload-contract)
  - [Finding the actions you have not registered yet](#finding-the-actions-you-have-not-registered-yet)
- [Reading one record's history](#reading-one-records-history)
- [Building an activity history in your own app](#building-an-activity-history-in-your-own-app)
  - [Generate it](#generate-it)
  - [A worked example](#a-worked-example)
  - [Writing the view yourself](#writing-the-view-yourself)
  - [Use `AuditLog::Pagination`, do not hand-roll one](#use-auditlogpagination-do-not-hand-roll-one)
  - [Four things to know](#four-things-to-know)
  - [Bounding it](#bounding-it)
  - [What the timeline covers](#what-the-timeline-covers)
- [Making association ids readable (optional)](#making-association-ids-readable-optional)
  - [The four things a cell can say](#the-four-things-a-cell-can-say)
  - [Configuring the label lookup](#configuring-the-label-lookup)
  - [Two things to know before turning it on](#two-things-to-know-before-turning-it-on)
- [Configuration](#configuration)
  - [The ones you should look at before deploying](#the-ones-you-should-look-at-before-deploying)
  - [Rendering and screens](#rendering-and-screens)
  - [Storage lifecycle](#storage-lifecycle)
  - [Rarely touched](#rarely-touched)
- [Generator options](#generator-options)
  - [The generators](#the-generators)
  - [`audit_log:trigger` options](#audit_logtrigger-options)
  - [`audit_log:views:activity` options](#audit_logviewsactivity-options)
- [Rake tasks](#rake-tasks)
  - [Schedule this one](#schedule-this-one)
  - [Run when something needs it](#run-when-something-needs-it)
  - [Retention: schedulable, in this order](#retention-schedulable-in-this-order)
  - [Only on a scratch database](#only-on-a-scratch-database)
- [Advanced](#advanced)
  - [Attaching to a table that already exists](#attaching-to-a-table-that-already-exists)
  - [Re-attaching, and changing a table's exclusions](#re-attaching-and-changing-a-tables-exclusions)
  - [Installing into a schema other than `public`](#installing-into-a-schema-other-than-public)
  - [Why objects and not relations](#why-objects-and-not-relations)
- [Why this one, and not a callback-based gem](#why-this-one-and-not-a-callback-based-gem)
- [Why not one of the popular gems?](#why-not-one-of-the-popular-gems)
- [Working on this library](#working-on-this-library)
  - [Files](#files)
  - [What reloads and what does not](#what-reloads-and-what-does-not)
  - [Before you change anything](#before-you-change-anything)
  - [Not implemented (deliberately)](#not-implemented-deliberately)

---

## Summary

An audit log that **cannot be bypassed**, because it does not run in Ruby.
PostgreSQL triggers write a field-level diff of every INSERT, UPDATE and DELETE,
so `update_all`, `delete_all`, `insert_all`, `upsert_all`, raw SQL, a database
cascade, a rake task and a console session are all captured — with the actor
attached — and no model has to opt in or even know.

- **Nothing in a model class.** No concern, no callback, no base class. The
  entire per-model cost is one line in a migration.
- **A callback-based gem cannot see `update_all`.** This one has no callbacks to
  bypass.
- **One `request_id` per unit of work.** A form submit that writes a parent and
  forty children reads as *one action with forty children*, not forty unrelated rows.
- **The actor comes along for free** — including into background jobs, which also
  record the request that enqueued them.
- **Coverage is a forcing function.** The build fails for any table that is
  neither audited nor exempted *with a written reason*. You cannot forget a table.
- **Two layers.** Field-level diffs (complete by construction) *plus* named
  business events with human sentences, joined by the same correlation id.
- **A finished auditor UI at `/audit`**, served by the gem — actor activity,
  record history, action reports, out-of-band review, drill-down, CSV export. It
  is not copied into your app and you do not maintain it; it upgrades with the gem.
- **Optional starter views** for your own pages, generated into your app and
  yours to rewrite. Plain CSS, Tailwind or Bootstrap.
- **Built for volume from day one.** Monthly range partitions, automatic
  rotation, retention, yearly rollup, verified export, `VACUUM FREEZE`.
- **GDPR erasure that keeps the evidence.** Redaction removes *values* and keeps
  the structure — "the email changed at 14:02, by Jane" stays provable after the
  address is gone.
- **Uncorrelated writes are surfaced, not hidden.** A console edit gets its own
  screen rather than blending in.
- **No silent truncation, anywhere.** Keyset paging, disclosed date bounds,
  uncapped exports. Every screen says what it searched.
- **Timestamps are UTC by construction**, not by convention — the app's
  `time_zone` cannot reach them.
- **A reconciler tells you what you have not named yet**, so the readable layer
  fills in over time instead of being an up-front project.
- **Ids in a diff read as records.** `product_id → Grommet 10mm (id: 51)`, with
  the recorded id never dropped.
- **Zero application constants.** Every coupling point is a lambda on
  `AuditLog.config`, so one library serves every app.

Already weighing this against `paper_trail`, `audited` or `logidze`?
[Why this one](#why-this-one-and-not-a-callback-based-gem) and
[Why not one of the popular gems?](#why-not-one-of-the-popular-gems) are at the
end, along with the cases where this gem is the **wrong** choice.

## Requirements

| | | Why it is a floor and not a preference |
|---|---|---|
| Ruby | **>= 3.3** | `SecureRandom.uuid_v7`, which is `Context.new_request_id`. On 3.2 every correlated write raises. UUIDv7 gives the `audit_changes(request_id)` index insert locality, and its embedded timestamp is what bounds the drill-down. DESIGN §2.1. |
| Rails | **`~> 8.0`** | 8.0 floor for `Rails.event` (with a fallback, and CI runs the suite on 8.0 so the fallback is exercised rather than assumed); ceiling below 9.0 because `TransactionStamp` prepends the *private* `raw_execute`. DESIGN §2.2. |
| PostgreSQL | **>= 16** | Layer 1 *is* a plpgsql trigger writing jsonb into range-partitioned tables, so this is not swappable for another database — but nothing here needs a recent Postgres. 16, 17 and 18 are all supported; CI runs the suite on 16 and 18. DESIGN §20. |

`pg` is deliberately *not* a dependency, so your app picks its own build. Nor is
`pagy`, or any other pagination gem: the audit screens are keyset-paginated by
`AuditLog::Pagination`, which is this library's own and depends on nothing, so
your app paginates however it already does — see
[Use `AuditLog::Pagination`](#use-auditlogpagination-do-not-hand-roll-one). The
one runtime dependency is `csv`, for the export.

Ruby **3.3.0 exactly** is unusable with Rails 8.1, for a reason unrelated to this
gem: actionview 8.1.3.1 contains `yield(*, **)` inside a block, which 3.3.0's
parser rejects, while Rails still declares `>= 3.2.0`. Any later 3.3 patch is fine.

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

## Demo Rails App

[`audit-log-demo`](https://github.com/web-ascender/audit-log-demo) is a small
Rails app that installs this gem the way the next section describes — seeded
data, emitted events, and the generated activity views on real pages. It is the demo app the rest of this file refers to as *the reference app*.

---

## Getting started

An existing Rails app with existing models. Work down the list; every step is a
command, and the reasoning for any of it is linked rather than inline.

### 1. Add the gem

```ruby
# Gemfile
gem "audit_log", git: "https://github.com/web-ascender/audit-log", tag: "v0.2.0"
```

A private repo, so `bundle` needs credentials for the company GitHub org. Pin to
a tag — without one, `bundle update` tracks `main` and moves the library under a
running app. Use `path: "../audit-log"` for local co-development.

### 2. Install

```bash
bin/rails generate audit_log:install
bin/rails db:migrate
```

Writes the initializer, the schema migration, the two `include`s, the engine
mount and the coverage spec — see
[What the generator wrote](#what-the-generator-wrote), which also lists what it
reports rather than does.

> ⚠️ **Confirm one thing before moving on.** The generator puts
> `include AuditLog::ControllerContext` after the last `before_action` it can
> find in `ApplicationController`. If it lands *ahead* of your authentication, it
> reads a `current_user` that is not resolved yet and **every audit row gets a
> NULL actor, silently.** Look at the file.

### 3. Attach a trigger to each audited table

```bash
bin/rails generate audit_log:trigger orders   --model=Order
bin/rails generate audit_log:trigger products --model=Product --exclude=search_vector
bin/rails db:migrate
```

One line per table, and the entire per-model cost of the design — nothing goes in
the model class. Which tables are worth auditing is a judgement about your
domain, so nothing can infer it for you.

Two things to know, both covered in
[Attaching to a table that already exists](#attaching-to-a-table-that-already-exists):
the table needs a `bigint` primary key named `id` or the first write after
attaching fails, and there is **no backfill** — rows that predate the trigger
have no history, so write the attach date down.

Flags: [`audit_log:trigger` options](#audit_logtrigger-options).

### 4. Prove nothing was missed

```bash
bin/rails audit_log:coverage
```

Fails until every table is either audited or listed in
`config.unaudited_tables` **with a written reason**. The generator also wrote a
spec asserting the same thing, so the decision cannot be skipped instead of made.

### 5. Schedule the daily task

```
0 2 * * *   bin/rails audit_log:partitions
```

**A missing future partition is a write-path outage**, not a degraded report.
This is the one task that belongs in a cron; the rest are in
[Rake tasks](#rake-tasks).

### 6. Read the initializer before deploying

`config/initializers/audit_log.rb`. `config.authorize` defaults to a **no-op**,
which is right for a demo and wrong for you. Everything else is in
[Configuration](#configuration).

At this point every change to an audited table is recorded, with an actor and a
correlation id, and readable at `/audit`. Neither step below is required for
that.

### 7. Recommended: Register and emit events for significant business actions

Two lines in two files — a declaration and a call — for each action worth a
sentence:

```ruby
# config/initializers/audit_log.rb
AuditLog::Registry.register "order.cancelled",
  subject: ->(p) { ["Order", p[:order_id]] },
  summary: ->(p) { "Cancelled order #{p[:number]} (#{p[:reason]})" }

# the controller, model or job — after the write succeeds
AuditLog.notify("order.cancelled", order_id: @order.id, number: number,
                reason: params[:reason])
```

This is what turns a complete log into a readable one: layer 2, the sentences an
auditor reads instead of a field diff. `bin/rails audit_log:reconcile` tells you
which actions you have not named yet, so it fills in over time rather than
up front. See
[Registering and emitting events](#registering-and-emitting-events).

### 8. Optional: Put a history on your own pages

```bash
bin/rails generate audit_log:views:activity Order Product LineItem
```

Then edit `RecordActivity#audit_activity_visible?`, which the generator prints in
red because it **denies everyone** until you do. Running it again later adds a
model and leaves your edits alone. See
[Building an activity history](#building-an-activity-history-in-your-own-app).


### What the generator wrote

Step 2 does all of this. Worth a look rather than a read — it reports anything it
could not do, and two of these need a decision from you.

| | What | Check |
|---|---|---|
| `config/application.rb` | `config.active_record.schema_format = :sql` | **Required, and required before your first migration** — `schema.rb` cannot represent partitioned tables or triggers. On an app that already has a `db/schema.rb` the generator **refuses** and tells you, rather than flipping it silently. |
| `config/initializers/audit_log.rb` | every coupling point, as a lambda | The only file that knows anything about your app. [Configuration](#configuration) is the full list. |
| `db/migrate/…_install_audit_log.rb` | `AuditLog::Schema.install!` | The two partitioned tables, their indexes, and the trigger function. |
| `ApplicationController` | `include AuditLog::ControllerContext` | ⚠️ **Must sit after whatever sets `current_user`** — see the warning in step 2. |
| `ApplicationJob` | `include AuditLog::JobContext` | The entire job-side integration. |
| `config/routes.rb` | `mount AuditLog::Engine => "/audit"` | Gate it. `config.authorize` is a no-op by default. |
| `spec/audit_log/coverage_spec.rb` | three lines, using a shared example | The forcing function. Shares `AuditLog::Coverage` with the rake task, so the two cannot disagree about what counts as covered. Do not weaken it to make a build pass. |

Re-running is safe: every step detects work already done and reports `skip`
rather than injecting twice. Flags: `--mount-at=/audit`, `--skip-migration`,
`--skip-routes`, `--skip-controller`, `--skip-job`, `--skip-spec`.

### What a model needs

Nothing! No include, no concern, no callback, no base class. An audited model is
an ordinary `ApplicationRecord`. The one line of per-model cost lives in the
migration, next to the table it audits.

## Registering and emitting events

Once the trigger is attached and `ControllerContext` is included, every row your
controllers touch is already being recorded — field by field, with no code in the
controller at all. **This section is optional**: layer 2 is the *sentence* over
the top of that, and skipping it costs you readability, never completeness.

It takes two pieces, in two files:

| | Lives in | Does |
|---|---|---|
| `AuditLog::Registry.register` | `config/initializers/audit_log.rb` | declares the action and renders its human summary |
| `AuditLog.notify` | the controller, model or job | emits it, carrying the payload that summary reads |
| `AuditLog.audited` | the model or service | the same emit, with the transaction opened for you — see [below](#letting-audited-open-the-transaction) |

You never pass the actor, IP, source, timestamp or `request_id`. All five come
from `AuditLog::Current`, which `ControllerContext` populated in a
`before_action` — the payload is only the domain detail.

### Registering actions

Actions with business significance should be registered in
`config/initializers/audit_log.rb`. Registering is how you customize action labels and define the primary model type and id, so it can be
queried correctly.

**This step is optional, but highly recommended.** Layer 1 triggers have already written a field-level diff of every row the
action touched, under the same actor and `request_id`. Registering gets you
readability, not completeness — the difference between an auditor reading
"Cancelled order SO-4471 (duplicate)" and reading four column diffs to infer it.

```ruby
AuditLog::Registry.register "order.created",
  description: "An order was placed for a customer.",
  subject: ->(p) { ["Order", p[:order_id]] },
  summary: lambda { |p|
    "Placed order #{p[:number]} for #{p[:customer]} — " \
      "#{ActiveSupport::NumberHelper.number_to_currency(p[:total_cents].to_i / 100.0)}"
  }

AuditLog::Registry.register "order.updated",
  subject: ->(p) { ["Order", p[:order_id]] },
  summary: ->(p) { "Edited order #{p[:number]} (#{Array(p[:fields]).join(', ')})" }

AuditLog::Registry.register "order.cancelled",
  description: "An order was destroyed, cascading to its line items.",
  subject: ->(p) { ["Order", p[:order_id]] },
  summary: ->(p) { "Cancelled order #{p[:number]} (#{p[:reason]})" }
```

#### `.register` options:

| | Shape | Purpose | Example | Stored on the row? |
|---|---|---|---|---|
| `summary:` <br><br> (required) | lambda → `String` | Describe a **specific occurrence**. Should usually include a noun, verb and some kind of human-friendly record descriptor | <span style="white-space: nowrap;">`"Submitted Order #{p[:number]}"`<span> | yes — `audit_events.summary`, rendered at emit and frozen |
| `subject:` <br><br> (optional - recommended) | lambda → `[type, id]`, optional | Track the model type and id (each occurrence) | `["Order", p[:order_id]]` | yes — `subject_type` / `subject_id`, indexed |
| `description:` <br><br> (optional - recommended) | `String` | What this action means, in general | `"An order was submitted for fulfillment."` <br> (for an action registered as `"order.submitted"`) | no — it lives only in this initializer |

**`summary:`** is the evidence sentence, and it is what every screen shows.
Interpolate the payload so each row says something specific: `Placed order
SO-4471 for Acme — $1,240.00`, not "an order was placed". It is rendered
**once, at emit time**, and stored, so editing the lambda changes what future
rows say and never what past rows said — a copy edit must not alter the
historical record.

**`subject:`** is a pointer, not prose; nothing renders it as text. It names the
aggregate root the action was about, and three things read those two columns: the
indexed half of a record's history screen, the events leg of `AuditLog::Timeline`,
and `redact_record!`, which finds an action's rows by subject — so **an entry
whose summary can carry personal data should always set it**, or a later erasure
request will not reach it (DESIGN §13). Omit it only for an action with no single
subject, such as a bulk price change; those rows still appear in a record's
*correlated* section, which is matched on `request_id` and capped.

**`description:`** is the glossary entry an auditor reads at the top of
`/audit/actions/order.cancelled` when they need to know what that name signifies
in your app. Write it once, in the present tense, about the action rather than
any occurrence of it. Because it is not stored, editing it changes what the
glossary says everywhere — which is right: it documents what the name means now,
not a historical claim about any event.

> [!NOTE]
> A call to `AuditLog.notify(...)` (or `AuditLog.audited`) for an action that is **not** registered is a silent no-op:
>- the event still reaches any other `Rails.event` subscriber, which is how
>  analytics events stay out of the audit tables;
>- the change rows land as they always would, so the record layer stays complete;
>- the activity simply has no `headline`, and a timeline renders it as
>  `:change_only` — the diff, with no sentence over the top of it;
>- `bin/rails audit_log:reconcile` lists it, which is how this file fills in over
>  time instead of being an up-front project. This is the first thing to check when an action does not show up on `/audit`.

### Emitting it: create, update, destroy

The payload keys below and the `p[...]` reads in the entry above are the contract
between the two files — nothing checks it for you, and a typo renders an empty gap
in a sentence.

```ruby
class OrdersController < ApplicationController
  before_action :set_order, only: %i[update cancel]

  def create
    @order = Order.new(order_params)

    # Emit INSIDE the success branch. An event for a save that failed
    # validation is a lie the audit log cannot take back.
    if @order.save
      AuditLog.notify("order.created",
        order_id:   @order.id,
        number:     @order.number,
        customer:   @order.customer.name,
        total_cents: @order.total_cents)
      redirect_to @order, notice: "Order created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @order.update(order_params)
      # `saved_changes` is a good payload: it says WHICH fields moved without
      # duplicating layer 1's before/after values, which audit_changes already
      # holds against this same request_id.
      AuditLog.notify("order.updated",
        order_id:   @order.id,
        number:     @order.number,
        fields:     @order.saved_changes.keys - %w[updated_at])
      redirect_to @order, notice: "Order updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def cancel
    # Read anything the summary needs BEFORE the row goes away.
    number = @order.number

    @order.destroy!
    AuditLog.notify("order.cancelled",
      order_id: @order.id, number: number,
      reason: params[:reason].presence || "no reason given")
    redirect_to orders_path, notice: "Order cancelled."
  end
end
```

### An action that spans several writes

Put the `notify` in the model or service, inside the same transaction as the
work, and let the controller stay a controller:

```ruby
# app/controllers/orders_controller.rb
def submit
  @order.submit!(by: current_user)
  redirect_to @order, notice: "Order submitted."
end

# app/models/order.rb
def submit!(by:)
  transaction do
    update!(status: "submitted", submitted_at: Time.current)
    line_items.each { |item| item.update!(unit_price_cents: item.product.price_cents) }
    customer.update!(balance_cents: customer.balance_cents + total_cents)

    # One notify for the whole action, not one per row: layer 1 already wrote a
    # row per row. Inside the transaction, so a rollback discards the sentence
    # along with the changes it describes.
    AuditLog.notify("order.submitted",
      order_id: id, number: number, line_count: line_items.size,
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

### Letting `audited` open the transaction

`AuditLog.audited` is sugar for exactly the shape above — it opens the
transaction, runs your block, and emits the event as the last statement inside
it. Same guarantees:

```ruby
# app/models/order.rb
def submit!(by:)
  AuditLog.audited("order.submitted", on: self,
                   order_id: id, number: number, approver: by.to_label) do |audit|
    update!(status: "submitted", submitted_at: Time.current)
    line_items.each { |item| item.update!(unit_price_cents: item.product.price_cents) }
    customer.update!(balance_cents: customer.balance_cents + total_cents)

    audit[:line_count]  = line_items.size
    audit[:total_cents] = total_cents
  end
end
```

**The payload is built in two places, and which half a key belongs to is the one
rule to learn:**

> **Identity and inputs are keyword arguments. Outcomes go through `audit`.**

Ids, references, a `reason` off params, the actor's label — the block cannot
change them, so they read naturally beside the action name, where the registry
entry's `subject:` lambda reads them. Counts, totals, a tracking number belonging
to a record the block has not created yet — those are produced *by* the writes,
so they can only be collected after them.

Putting an outcome in the keyword slot records **pre-write** state under a
sentence describing the write. `total_cents` above is recalculated from the line
items the block reprices; passed as a keyword it would file the pre-submit total
under "order submitted", and the screen would render it without complaint.
Nothing can mechanically prove a value is an input, so the guard that exists is
the one that can be built: **a key set in both slots raises**, and says which
slot to remove it from.

`audit` takes keys three ways, all equivalent:

```ruby
audit[:line_count] = line_items.size                        # assignment
audit.merge!(line_count: line_items.size, total_cents: n)   # keywords
audit.merge!({line_count: line_items.size})                 # a hash
```

`audit.merge` — without the `!` — raises rather than doing what Ruby's
convention says it does, which on a collector would be to build a hash, discard
it, and emit the event without those keys.

Two more things worth knowing:

**Pass `on:`.** It is what opens the transaction, and it defaults to
`ActiveRecord::Base` — right for a single-database app, and wrong for a model on
a secondary connection via `connects_to`, where that transaction would wrap none
of your writes and a rollback would discard nothing while appearing to work.
`on: self` inside a model instance method, or the model class, is right by
construction.

**The emit is inside the transaction, not after commit.** "Only if the writes
succeeded" comes free — a raise never reaches the last statement — and the
guarantee holds in the other direction too: if the event write fails, the
business changes roll back with it. An `after_commit` emit would leave the
changes standing with no narrative.

`audited` returns the block's value, so a method can still return what it built:

```ruby
def ship!(carrier:)
  AuditLog.audited("order.shipped", on: self, order_id: id, carrier: carrier) do |audit|
    shipment = shipments.create!(carrier: carrier)
    update!(status: "shipped")

    audit[:tracking_number] = shipment.tracking_number   # did not exist until now
    shipment                                             # ...and this comes back to the caller
  end
end
```

The explicit `transaction do ... AuditLog.notify ... end` form is not deprecated
and never will be. Use it wherever several notifies belong in one transaction.

### An action whose writes skip Active Record

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

### An action that only enqueues work

Do not emit anything for the enqueue. Once `ApplicationJob` includes
`AuditLog::JobContext` ([step 2](#2-install)), the job inherits this request's
actor and records this request as its `caused_by_request_id`; the job emits its
own event when the work actually happens:

```ruby
def ship
  OrderShipmentJob.perform_later(@order)
  redirect_to @order, notice: "Shipment queued."
end
```

An event emitted here would claim the order shipped at the moment somebody
clicked a button, which is not what happened.

### Payload rules

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
- **A missing key is silent unless you declare it.** See
  [Declaring a payload contract](#declaring-a-payload-contract) below.
- **Do not rescue around `notify`.** The engine sets
  `Rails.event.raise_on_error = true` on purpose: a failed audit write must not
  vanish while the change it described commits anyway.

### Declaring a payload contract

The payload keys a call site passes and the `p[...]` reads in the registry entry
are a contract between two files, and by default nothing checks it. A typo on
either side renders a gap in a stored sentence — and summaries are frozen at
emit time, so that gap can never be repaired.

`requires:` is the third point that makes the two agree:

```ruby
AuditLog::Registry.register "order.submitted",
  requires: %i[order_id reference customer_name line_count total_cents],
  subject: ->(p) { ["Order", p[:order_id]] },
  summary: ->(p) { "Submitted order #{p[:reference]} — #{p[:line_count]} line items" }
```

Emit `order.submitted` without `line_count` — from `notify`, from `audited`, or
from a bare `Rails.event.notify` — and it raises `AuditLog::MissingPayloadKeys`
naming the key. Because the check runs where the row is written, it is inside
your transaction: the change rolls back rather than committing beside a sentence
with a hole in it, which is the same position the engine takes with
`raise_on_error`.

Four things about it are deliberate:

- **It is opt-in per entry.** An entry with no `requires:` is unchecked, exactly
  as before. That is what keeps this from being a landmine — a raise in
  production is only reachable where somebody deliberately wrote a contract, and
  an app adopts it action by action the way the registry itself fills in.
  Deleting the line is the escape valve; there is no config flag to soften the
  check.
- **Extra keys pass, and are still stored.** Payloads legitimately grow, and a
  call-site typo is already caught by the missing half — `refernce:` means
  `reference` is absent.
- **It checks that the key is present, not that the value is.** `metadata` is
  stored `.compact`ed, so a deliberate `reason: nil` and a forgotten `reason:`
  produce an identical row. The declaration is the only place that distinction
  survives.
- **List what the entry cannot render without, not every key it reads.** A
  summary spelled `Array(p[:columns]).presence || "all values"` has already
  decided that key is optional; requiring it contradicts the entry.

### Finding the actions you have not registered yet

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

**Optional, and starter code.** The gem is complete without any of this —
`/audit` is a finished auditor UI served by the engine, and nothing depends on
what the generator writes. What it produces lands in your app and belongs to you:
plain ERB, no markup lock-in, never re-generated, never upgraded. If you would
rather write the view yourself, `AuditLog::Timeline`'s value objects below are
the real contract, and the generated files are one worked answer to it.

The auditor UI is for auditors. For an *"activity history"* on your own
`orders/show`, in your own markup, use `AuditLog::Timeline` — a paginated list of
**units of work**, each one carrying its narrative, that record's field changes,
and the other records the same action touched.

**The fast path is the generator**, below. Everything after it is what the
generator produces and the contract underneath, for when you want to change it or
write your own.

### Generate it

You do not have to write any of the above by hand:

```bash
rails generate audit_log:views:activity Order Product Customer
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
rails generate audit_log:views:activity Invoice Shipment
```

That second run adds both to the allowlist, wires up their show pages, and
**leaves every generated file alone** — they are yours the moment they land, and
a generator that quietly reverses an edited authorization rule is worse than no
generator. `--force` re-baselines everything against the current templates when
you actually want that.

### A worked example

[The reference app](https://github.com/web-ascender/audit-log-demo) renders this
on its order, product and customer pages, and on a paginated history of its own
at `/activity/:record_type/:record_id` — its own markup, its own i18n for the
sentence this library refuses to invent, its own `record_url` lambda, its own
role check. Nothing but the contract above:

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

### Writing the view yourself

```ruby
class OrdersController < ApplicationController
  include AuditLog::Pagination      # the gem's keyset pager — see below

  def show
    @order      = Order.find(params[:id])
    timeline    = AuditLog::Timeline.for(@order)
    @page       = paginate(timeline.activity_keys, limit: 20)
    @activities = timeline.activities(@page.records)
  end
end
```

And the view it feeds:

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

`AuditLog::Timeline.new(record_type:, record_id:)` is the same thing without a
record in hand — which is what you want for a **deleted** record, since an audit
trail outlives what it describes and that is exactly when somebody reads it.

### Use `AuditLog::Pagination`, do not hand-roll one

`include AuditLog::Pagination` gives you `paginate(scope, limit:)`, reading the
cursor from `params[:page]`. It is not a convenience.

A keyset cursor is serialised with `to_json`, and ActiveSupport renders a
`Time` at **millisecond** precision — while `occurred_at` is `clock_timestamp()`,
which is **microseconds**. A pager that does not override that mints a cursor
naming an instant just before the row it came from, and the next page's
`occurred_at < cursor` skips everything in the gap. **Rows vanish between pages,
silently.** It presents as a rare flake, not as an error; it took roughly one
full-suite run in eight to surface here before it was fixed.

`AuditLog::Pagination::FULL_PRECISION` is the fix, and including the module is
how you get it. It also falls back to the first page on a cursor minted for a
different screen, rather than raising or — worse — applying it and dropping rows.

It brings no dependency with it, and that is deliberate. Bundler resolves one
`pagy` per app; this module needs `Pagy::Keyset` (9.0+) *and* the
`jsonify_keyset_attributes:` hook (9.3+, removed again in Pagy 43), so depending
on Pagy would have pinned your app to two of its releases. Paginate the rest of
your app with whatever you like — these screens are unaffected by it.


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

### Configuring the label lookup

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

## Configuration

> The next three sections — **Configuration**, **Generator options** and **Rake
> tasks** — are lookup tables rather than reading. The guides above tell you
> which of these you need; these tell you what they all are.

Everything this gem needs to know about your application, in one file. The
install generator writes `config/initializers/audit_log.rb` with the ones that
matter commented in place; this is the whole list.

**Nothing here names one of your constants.** Every coupling point is a lambda or
a string you supply, which is what lets one library serve every app without
knowing anything about any of them.

### The ones you should look at before deploying

| | Default | Does |
|---|---|---|
| `authorize` | **no-op** | Gates the auditor UI at `/audit`. The default lets *everyone* in, which is right for a demo and wrong for you. Raise or redirect. |
| `actor_resolver` | `controller.try(:current_user)` | How to find the acting user. Works with Devise, the Rails generator, or anything exposing `current_user`. |
| `actor_label_resolver` | `actor.to_label` | The string snapshotted onto every audit row. Rendered once per entry point, so a later rename never rewrites history. |
| `unaudited_tables` | a few internals | Tables that legitimately have no trigger, **each with a written reason**. `audit_log:coverage` fails for anything neither audited nor listed here. |
| `default_excluded_columns` | timestamps, `lock_version`, password and reset-token columns | Columns kept out of every diff. Per-table extras go on the trigger via `--exclude`. |
| `retention` | `7.years` | How long partitions are kept before `retention` will detach them. `nil` disables it. |

### Rendering and screens

| | Default | Does |
|---|---|---|
| `parent_controller` | `"ApplicationController"` | What the engine's controllers inherit, which is how they pick up your layout and authentication. |
| `record_url` | `nil` | `->(type, id)` returning a path in **your** app, for a history you render yourself. nil means labels render unlinked, ids intact — it will not guess a route. |
| `page_size` | `50` | Rows per page on the auditor screens. Keyset-paginated, so there is no cost curve behind it. |
| `actor_picker` | `[]` | Populates the actor search on `/audit/actors`. Source it from your users table, not from the log. |
| `actor_finder` | `type.constantize.find_by(id:)` | Looks up an actor for display when the log holds no snapshot. |
| `record_label_resolver` | `RecordLabel.batch` | Turns ids in a diff into labels. `nil` disables labelling entirely. **Scope it in a multitenant app** — the default reads business tables unscoped. |
| `association_targets` | `{}` | `{"LineItem" => {"product_id" => "Product"}}` for association columns `belongs_to` reflection cannot see. `false` suppresses one. |
| `drill_down_slack` | `24.hours` | How wide the date window around a `request_id` drill-down is. Generous on purpose, and disclosed on screen. |

### Storage lifecycle

| | Default | Does |
|---|---|---|
| `partition_months_ahead` | `3` | How far ahead the daily task provisions. A missing future partition is a write-path outage. |
| `rollup_after` | `2.years` | How cold a year must be before `rollup` consolidates its months. `nil` disables it. |
| `archive_dir` | `nil` | Default `DIR` for the export tasks. |
| `maintenance_lock_timeout` | `"5s"` | How long the three `ACCESS EXCLUSIVE` operations wait before failing rather than blocking every audited write. |

### Rarely touched

| | Default | Does |
|---|---|---|
| `correlated_connections` | `%w[primary]` | Which **connections** carry the correlation context — connection names as they appear in `database.yml` (`primary`, `queue`), *not* database names. The default is right for nearly every app, **including one whose `database.yml` has no `primary:` key**: Rails names a flat single-database config `primary`. **Does not decide what is audited** — a connection left out is still fully audited, its rows just arrive with no actor. The engine refuses to boot if this matches no connection, because that failure is otherwise silent. |
| `bypass_allowlist` | `[]` | Classes permitted to call `AuditLog.without_logging`. Empty means the bypass is unavailable, which is the right default. |
| `raise_on_subscriber_error` | `true` | Whether a failed layer-2 write raises. Leaving it true is what stops an audit failure vanishing while the change it described commits. |

## Generator options

Every flag the three generators take. `audit_log:install`'s are listed with the
step-by-step in [What the generator wrote](#what-the-generator-wrote); the two below
are the ones with decisions in them.

### The generators

| | Does | Run it |
|---|---|---|
| `audit_log:install` | initializer, schema migration, `ControllerContext` and `JobContext` includes, mounts the engine, coverage spec | once |
| `audit_log:trigger TABLE --model=Model` | a migration with one `attach_audit_trigger` line | once per audited table |
| `audit_log:trigger TABLE --replace` | detach-then-attach, to change a table's model or exclusions | when those change |
| `audit_log:views:activity Model [Model...]` | controller, concern, helper, views, route, locale, stylesheet — and wires each model's show page | once, then again per new model |

### `audit_log:trigger` options

```bash
bin/rails generate audit_log:trigger orders \
  --model=Order \
  --exclude=internal_notes search_vector
```

| | |
|---|---|
| `--model=Order` | the model name recorded on every `audit_changes` row. Defaults to the table name classified — pass it when they differ, because this string is what every screen filters and groups on. |
| `--exclude=a b c` | columns kept **out of the diff**, on top of `config.default_excluded_columns` |
| `--replace` | detach first. Required to change an existing trigger's model or exclusions — see [Re-attaching](#re-attaching-and-changing-a-tables-exclusions). |

**What `--exclude` is for.** The trigger writes a diff of every column that
changed. Some columns change constantly and mean nothing to an auditor, and a few
should never be copied anywhere at all:

- **Noise that would drown the signal.** A `search_vector`, a denormalised
  counter, a `last_seen_at` touched on every request. Left in, an auditor reading
  "what changed on this order" wades through a column nobody asked about, and the
  jsonb `diff` grows for no benefit.
- **Values you do not want a second copy of.** `config.default_excluded_columns`
  already covers the usual suspects — `created_at`, `updated_at`,
  `lock_version`, `password_digest`, `encrypted_password`, and Devise's reset
  tokens. `--exclude` is for the ones only your schema knows about: an API secret,
  a bearer token, a column holding something a customer can ask you to erase.

**What it does not do.** Excluding a column does not stop the row being audited.
The change is still recorded — who, when, under which `request_id`, and every
*other* column that moved. Only that column's before/after values are left out.

That distinction is the reason to reach for `--exclude` rather than
`unaudited_tables`: the latter drops the whole table from the log and needs a
written reason to pass `audit_log:coverage`.

> **Excluding is not retroactive, in either direction.** A newly excluded column
> stops appearing from the re-attach forward and **stays in the history written
> before it** — `AuditLog::Redaction` is the tool for values already recorded.
> And un-excluding one does not recover the values that were never captured.

Changing exclusions later means `--replace`, because attaching is deliberately
not idempotent: a second attach on the same table fails with `42710` rather than
letting two triggers coexist and write two rows per change under different
exclusion sets.

### `audit_log:views:activity` options

`audit_log:views:activity` takes **any number of models in one call**, and calling it
again later is how you add more. Both reach the same place:

```bash
bin/rails generate audit_log:views:activity Order Product LineItem
# ...is equivalent to:
bin/rails generate audit_log:views:activity Order
bin/rails generate audit_log:views:activity Product LineItem
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

## Rake tasks

Registered by the engine, so they appear in any host app's `bin/rails -T`.

**One is mandatory in cron; two others belong there too, with conditions.**
`audit_log:partitions` is operationally required, and it now folds freezing in,
so there is nothing to schedule for that. `retention` and `rollup` are the two an
app with a compliance horizon will *want* scheduled — retention that depends on
somebody remembering, monthly, for seven years, is not retention.

The condition on both is the same. They take `ACCESS EXCLUSIVE` on an audit
table, which blocks **every audited write in your application** while it runs, so
they belong in a low-traffic window. They fail fast rather than queueing
(`config.maintenance_lock_timeout`, 5s) because a pending `ACCESS EXCLUSIVE`
blocks every lock behind it — an unbounded wait behind one long reader would
stall the write path.

> **A scheduler that discards output turns that design into a silent skip.** Lock
> contention and lock timeouts **raise**, so a bad moment gives you a non-zero
> exit and a retry next cycle. That is only true if something is watching. And
> `retention` and `rollup` commit **per partition**, so a mid-run failure leaves
> the earlier ones already done — keep the output, not just the exit status.

### Schedule this one

| Task | What it does | Why, and when |
|---|---|---|
| `audit_log:partitions` | Creates missing monthly partitions, **freezes newly closed ones**, and warns on default-partition overflow and retired leftovers | **Daily, in cron. Non-negotiable.** A missing future partition is a **write-path outage**, not a degraded report — every audited write fails once the calendar passes the last partition. Keeps `config.partition_months_ahead` (3) provisioned. Creation commits before the freeze, so a slow `VACUUM` can never delay the half that matters. |

### Run when something needs it

| Task | What it does | Why, and when |
|---|---|---|
| `audit_log:coverage` | Lists tables in the primary database with no audit trigger | **In CI, not cron.** The forcing function. Fails for any table that is neither audited nor in `config.unaudited_tables` **with a written reason**. Run it in CI — it is what stops a table added next month being quietly unaudited. |
| `audit_log:reconcile` | Reports correlated changes with no registered action | Tells you which narratives are still missing, so layer 2 fills in over time instead of being an up-front project. Run after adding controllers. |
| `audit_log:partitions:drain_default` | Moves rows out of the default partition into the ones that should hold them | When `partitions` reports default-partition overflow. **Do not schedule this one.** Needing it means a row landed in the default partition, which means the rotation task was not running — scheduling the repair hides the fault that caused it. Takes `ACCESS EXCLUSIVE`. Stages through a temp table in one transaction, so a failure leaves the rows where they started. |
| `audit_log:redact` | Removes a record's **values** from the log, keeping the structure | An erasure request. `RECORD=Customer:42 REASON=DSR-1182 [FIELDS=email,phone] [DRY_RUN=1]`. The only thing permitted to modify audit rows; it narrates itself in the same transaction. `changed_columns` survives, so *"the email changed at 14:02, by Jane"* stays provable. |

### Retention: schedulable, in this order

Every state named below is defined in
[DESIGN §8, The partition lifecycle](DESIGN.md) — including which states the gem
can still see, and which are DBA-only.

| Task | What it does | Why, and when |
|---|---|---|
| `audit_log:partitions:rollup` | Consolidates closed years of monthly partitions into yearly ones | **Monthly or quarterly** is reasonable. Fewer partitions to plan against once a year is cold. `DRY_RUN=1` to preview. Only rolls up years past `config.rollup_after` (2y) — **it coarsens retention**, since a yearly partition can only be retired whole. Takes `ACCESS EXCLUSIVE`. |
| `audit_log:partitions:retention` | Detaches partitions past the horizon and marks them **retired** | **Monthly** is the obvious cadence, and scheduling it is the point of having a horizon. `config.retention` (7y). **It cannot drop anything** — there is no option to make it — so a scheduled run can only take data out of service, never destroy it. `DRY_RUN=1` to preview. Takes `ACCESS EXCLUSIVE`. |
| `audit_log:partitions:export_retired` | Streams **every** retired partition to `DIR` as gzipped CSV + manifest, verifying each | `DIR=/backups/audit`. Exports everything, every run — it does not skip what it exported before, because a file existing in `DIR` is not evidence it is intact or that it ever reached durable storage. Writes through a temp file, so a re-export cannot destroy a good archive. Reports total bytes, which is what tells you whether to be dropping more aggressively. |
| `audit_log:partitions:export_and_drop_retired` | Exports, verifies, then drops only what verified | **The recommended disposal path.** `DIR=/backups/audit`, optional `BEFORE=YYYY-MM-DD`. Verifies by checksum **and** row count, and anything that fails is reported and left alone. Safe to re-run: export skips nothing, and the drop only takes what passed. |
| `audit_log:partitions:drop_retired` | Drops retired partitions **without** checking for an export | ⚠️ **Irreversible, and does not look for a backup.** `DRY_RUN=1` first; optional `BEFORE=YYYY-MM-DD`. Offered because a CSV in a directory is not proof of preservation, so requiring one buys less safety than it appears to — and forcing everyone to produce archives they do not want is not this library's call. The judgement that mattered was made upstream by `retention`; this reclaims the disk. |
| `audit_log:partitions:freeze` | `VACUUM FREEZE` closed partitions that are not already frozen | **You do not need to schedule this** — `audit_log:partitions` does it daily. It is here as a manual catch-up, plus `FORCE=1` to redo partitions already marked frozen. |

**`BEFORE=` compares the upper bound**, which is what the retirement marker
records — so `BEFORE=2025-06-01` does *not* drop a `2025` yearly partition,
because that partition holds data through `2025-12-31`. A partition whose marker
cannot be read is skipped by a date-bounded drop rather than guessed at, and the
task says which.

**Freezing is automatic and you should not have to think about it** — but it is
worth knowing what it is for.

PostgreSQL decides row visibility by comparing 32-bit transaction ids, and that
counter wraps. To stay correct it must eventually mark old rows *frozen* —
"visible to everyone, no comparison needed" — and if nothing does that in time it
forces an **anti-wraparound vacuum** that scans the whole table, runs even where
autovacuum is disabled, and picks its own moment. Your audit tables are the
largest in the database and append-only, which is exactly the shape that gets
ignored by ordinary vacuuming until wraparound forces the issue.

So freezing is not optional in the end; *choosing when* is the only thing
actually on offer. Doing it as each month closes turns one unpredictable
full-table scan into a bounded operation on one partition, per table, per month —
and a closed partition never changes again, so it is frozen once and then skipped
by every future vacuum.

Each frozen partition is marked, so the daily task does exactly the newly closed
ones: nothing on most days, one partition per table on the first run of a month.
[DESIGN §8](DESIGN.md) has the mechanism in full.

The one thing that un-freezes a partition is a **redaction**, which updates the
parent table and so dirties pages in whatever partitions held the redacted rows.
It clears the markers, and the next daily runs freeze them again.

**Only partitions this gem retired are ever exported or dropped.** A table merely
*named* like a retired partition — a manual copy taken before a risky migration,
say — carries no marker and is reported, never touched. That is the same rule
that keeps rollup from dropping somebody's `audit_events_2019`.

### Only on a scratch database

| Task | What it does | Why, and when |
|---|---|---|
| `audit_log:benchmark` | Generates volume and `EXPLAIN`s the canonical auditor queries | `ROWS=100000`. **Writes synthetic rows into your real audit tables.** Use a scratch database or clean up after. |
| `audit_log:benchmark_cleanup` | Deletes the synthetic rows `benchmark` wrote | Immediately after `benchmark`, unless the database is disposable. |

> **`redact` takes `FIELDS=`, never `COLUMNS=`.** `COLUMNS` is a reserved shell
> variable holding your terminal width, so `COLUMNS=email rails audit_log:redact`
> arrives as a number, matches no column, and **redacts nothing while reporting
> success**. Found by running it.

---

## Advanced

Everything above is enough to install this gem, use it, and put a history on
your own pages. What follows is the reasoning behind the parts most likely to
surprise you — worth reading when one of them does, and skippable until then.

The full design record lives in [`DESIGN.md`](DESIGN.md), which is the
authority on *why* anything here is shaped the way it is.

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

- **[Step 2](#2-install) must already have run.** `CREATE TRIGGER` resolves
  `audit_row_change` at creation time, so a missing install fails the migration
  loudly. This is the harmless one.
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

### Installing into a schema other than `public`

Everything installs into the **current schema** — the first entry on the
connection's `search_path`. For a normal Rails app that is `public` and there is
nothing here to do.

It matters if your app puts data in more than one schema, because the audit
tables, their partitions and the trigger function all have to agree on which one.
They do: `AuditLog::Schema.install!` creates the tables and the function together
in whatever schema is current, and `attach_audit_trigger` binds each trigger to
the function copy sitting beside it. Run the install once per schema and each one
gets an independent, self-contained audit log.

```ruby
# In a schema-per-tenant app (ros-apartment and friends), migrations already run
# once per tenant with that tenant's search_path active -- so the ordinary
# install migration does the right thing per tenant with no changes.
#
# What does NOT sweep automatically is anything scheduled. The daily task is the
# one whose failure is a write-path outage, so it is the one to get right:
Apartment::Tenant.each { AuditLog::Partitions.ensure! }
```

The same wrapping applies to `audit_log:coverage`, `audit_log:reconcile`,
`audit_log:redact` and the retention tasks — each acts on one schema per call.
This gem has no tenancy configuration and names no tenancy library; it only
declines to assume `public`.

Three things to know:

- **A trigger's destination is fixed when it is attached, not when it fires.** A
  table in `public` that is written while another schema's `search_path` is
  active still files its audit rows in `public`, where the table lives. That is
  what you want for records deliberately kept outside per-tenant data.
- **If you provision a schema by cloning another one** rather than by migrating
  it, call `AuditLog::Schema.install_function!` in that schema afterwards. A
  clone may carry a function still pointing at the schema it was copied from, and
  that failure is silent — rows land in the wrong table and everything reports
  success.
- **`rake audit_log:coverage` will ask about tables you consider dead.** A schema
  cloned from a template contains every table in the template, including ones
  that schema never uses. Exempt them in `config.unaudited_tables` with a reason.

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

They are separate because keyset paging needs a *relation* to build a cursor from, because
hydration has to be batched, and because the limit belongs above the controller
where you can see it (DESIGN §11.0 Rule 2) — so the library cannot paginate and
load in one call.

## Why this one, and not a callback-based gem

The comparison, kept to the end because the [Summary](#summary) already covers
what this gem does — this is the part you want when deciding *whether* rather
than *how*.

Most audit gems hook Active Record callbacks, which works until the first
`update_all`, the first `dependent: :delete_all`, the first data-fix script — and
then the log is missing exactly the writes somebody will later ask about, with
nothing anywhere reporting the gap. Being *mostly* complete is the one property
an audit log cannot trade away, and you discover you traded it at the worst
possible moment.

Integration is genuinely small: a generator, one migration line per table, and
two `include`s the generator writes for you. Nothing about your models changes.
Bending it is small too — every hook into your app is a lambda you own, the
auditor UI needs nothing from you, and the optional activity views are generated
*into* your app rather than served from the gem, so you can rewrite them
completely and nothing here will notice.

## Why not one of the popular gems?

They are good gems. This exists because of one architectural difference and a few
consequences of it.

| | Why not |
|---|---|
| **paper_trail** | Model callbacks, so bulk writes and raw SQL never reach it, and every model must opt in — nothing tells you which one you forgot. Excellent at *versioning*: if you want `reify` to restore a record to a previous state, use it. This gem records what changed, and does not rebuild past objects. |
| **audited** | Same callback architecture, same blind spots, same per-model opt-in. Simpler to adopt than this if your writes all go through Active Record and you do not need partitioning, retention or an auditor UI. |
| **logidze** | Also trigger-based, and the closest relative here. It stores history **in the audited row itself** (a `log_data` column), which is elegant and fast — but it means deleting the record deletes its history, the row carries its own past forever, and there is no separate table to partition, retire or export. If what you need is "what did this row look like last Tuesday", it is a very good answer. If you need the record of a deletion to outlive the record, it structurally cannot be. |
| **Rolling your own triggers** | Entirely reasonable, and roughly the first two days of this. The rest is what took the time: correlation through jobs, partition lifecycle, retention, redaction that survives an audit, and the forcing function that stops a new table being quietly unaudited. |

**Where this gem is the wrong choice**, stated plainly:

- **PostgreSQL only.** Layer 1 *is* a plpgsql trigger writing jsonb into
  range-partitioned tables. Any Postgres from 16 up, but there is no MySQL path
  and there will not be one.
- **It requires `schema_format = :sql`**, which must be set before your first
  migration. An established app switching to it re-dumps its whole schema.
- **No object restoration.** No `reify`, no "roll this record back". It answers
  what changed and who did it, not "give me the January version of this order".
- **Read-access logging is out of scope.** This records changes, not views.

---

## Working on this library

Only relevant if you are changing the gem itself rather than using it.

[`CLAUDE.md`](CLAUDE.md) is the terse companion to this section: the same
decisions as a list of things not to "fix", for anyone — human or otherwise —
who will not read a 2,600-line design document first.

### Files

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
| `lib/generators/audit_log/` | `audit_log:install`, `audit_log:trigger` and `audit_log:views:activity`, with templates. |
| `DESIGN.md` | Why every decision here is what it is. Cited by section number from source comments. |
| `lib/audit_log/tasks/audit_log.rake` | `partitions` and the `partitions:` namespace, plus `redact`, `reconcile`, `coverage`, `benchmark`. Full list in [Rake tasks](#rake-tasks). |

---

### What reloads and what does not

The gem loads its own files two ways, and only one of them reloads in a host
app's development environment:

| Path | Loader | Reloads? |
|---|---|---|
| `app/**` (queries, models, controllers, helpers, views) | Zeitwerk, via the engine | **yes** |
| `lib/audit_log/*.rb` (`configuration`, `context`, `partitions`, `schema`, …) | `Kernel#autoload`, from `lib/audit_log.rb` | **no** — once per process |

**Editing anything directly under `lib/audit_log/` requires a server restart.**
This matters in practice when you consume the gem by path, as
[the reference app](https://github.com/web-ascender/audit-log-demo) does: an `app/**` edit shows up on the next request, a `lib/**` edit does not.

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

### Before you change anything

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
are stable. Sections 15, 18 and 19 were project rollout and now live in the
reference app's [`ROLLOUT.md`](https://github.com/web-ascender/audit-log-demo/blob/main/ROLLOUT.md).

### Not implemented (deliberately)

Per [`DESIGN.md`](DESIGN.md) §12, §13, and the open questions in the reference
app's [`ROLLOUT.md`](https://github.com/web-ascender/audit-log-demo/blob/main/ROLLOUT.md):

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
partitions** (`archive.rb`, `rake audit_log:partitions:export_retired`) and **PII redaction**
(`redaction.rb`, `rake audit_log:redact`). What remains open about redaction is
policy, not mechanism: who may authorize one, and what makes a `REASON` valid.
