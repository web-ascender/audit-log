# CLAUDE.md — audit_log

Guidance for Claude Code working in this gem.

> Copyright (c) 2026 Web Ascender. All rights reserved. CONFIDENTIAL AND
> PROPRIETARY. Internal use only — see `LICENSE.txt`. The gemspec sets
> `allowed_push_host` to a non-host so `gem push` fails; never publish this.

## What this is

A two-layer audit log for Rails 8 + PostgreSQL, packaged as a `Rails::Engine`.
[`DESIGN.md`](DESIGN.md) is the authority on *why* anything here is shaped the way
it is, and the section numbers cited from source comments (`plan §6.1`,
`§11.0 Rule 1`) are its.

| | For | Contains |
|---|---|---|
| `README.md` | someone installing the gem | install, use, the auditor UI |
| **`CLAUDE.md`** (this file) | you | terse rules, and what not to "fix" |
| `DESIGN.md` | someone changing the library | the reasoning, in full |
| `CHANGELOG.md` | everyone | what changed and why |

The list of deliberate decisions below is deliberately terse and deliberately
duplicated from `DESIGN.md` — it exists so an agent that will not read a
2,000-line document still does not "fix" a decision. **When the two disagree,
`DESIGN.md` is right; fix this file.**

Two layers, joined by a `request_id` (UUIDv7):

- **Layer 1** — PostgreSQL `AFTER ... FOR EACH ROW` triggers write a jsonb
  field-level diff to `audit_changes`. Nothing bypasses it: not `update_all`,
  `delete_all`, `insert_all`, `upsert_all`, a DB cascade, raw SQL, a rake task,
  or a console session. This is the entire reason the design exists.
- **Layer 2** — the app emits named events via `AuditLog.notify`; one durable
  subscriber writes a human-readable row to `audit_events`.

The reference implementation is `../audit-log-demo`, a Rails app that consumes
this gem by path. It is where the demo domain, Devise, Solid Queue and the seed
data live — none of which this gem knows about. Its `orders/show` renders
`AuditLog::Timeline` in its own markup, which is the only place this library's
host-facing contract is exercised by a real host rather than asserted by our own
specs — **if you change a Timeline value object, check that app renders**.

## The one rule that matters most

**This gem must never reference an application constant.** No `User`, no
`Order`, no `ApplicationRecord`, no Devise, no app I18n key. Every coupling point
is a lambda or string on `AuditLog.config`, configured in
`config/initializers/audit_log.rb`. If you need the library to know something
about the host app, add a config attribute — do not reach for the constant.

It assumes only that the host app exposes `current_user` in controller scope and
that the actor responds to `to_label`. Both are resolved through config.

`README.md` is the extraction guide and the design-decision record.
Update it when you change behaviour.

## Environment

| | |
|---|---|
| Ruby | **>= 3.3** — the floor is `SecureRandom.uuid_v7` (DESIGN §2.1), not a preference. 3.3.0 exactly also cannot run Rails 8.1, for a reason of Rails' own. Developed on 4.0.6. |
| Rails | **`~> 8.0`** — floor 8.0 (DESIGN §2.2), and a real ceiling below 9.0 because `TransactionStamp` prepends the *private* `raw_execute`. Developed on 8.1.3.1. |
| PostgreSQL | **18.6 on port 5438** — not the workspace default 5437 |
| Tests | RSpec against `spec/dummy` (308 examples), on every push via GitHub Actions |
| Runtime deps | `rails`, `pagy` (keyset paging), `csv` (export). **`pg` deliberately is not one** — the host app picks its build. |

```bash
bundle install
cd spec/dummy && RAILS_ENV=test bundle exec bin/rails db:create db:migrate
bundle exec rspec                       # from the gem root
bundle exec rspec spec/preview.rb       # renders all 17 engine screens to spec/dummy/public/
```

`spec/dummy/db/structure.sql` is **git-ignored on purpose**. For a disposable app
it does more harm than good: `db:migrate` loads it in preference to re-running
the migrations, so editing a migration silently does nothing. Delete it and
re-migrate if a schema change appears not to apply.

## Things that look like bugs but are deliberate

Do not "fix" these without reading the linked reasoning first.

- **`audit_log:install` refuses to set `schema_format` when `db/schema.rb`
  exists, and that refusal is a feature.** `:sql` is required *before* the first
  migration; switching an established app means re-dumping its whole schema and
  every developer rebuilding their database. A generator must not start that
  quietly — it reports the three steps and stops.
- **The `ControllerContext` include is injected after the LAST `before_action`,
  not at the top of the class.** `inject_into_class` puts it at the top, which
  puts `set_audit_context` ahead of `authenticate_user!` — so it reads a
  `current_user` that is not resolved yet and **every audit row gets a NULL
  actor, silently.** This was a real bug in the first version of the generator.
  The generator also prints a "confirm this" note, because anchoring on the last
  `before_action` is a good guess and not a certainty.
- **`config.active_record.schema_format = :sql` is required of the host app.**
  Not optional and not this gem's to set: `schema.rb` cannot represent
  partitioned tables, trigger functions, or triggers. It must be set before the
  first migration exists, which is why the install generator refuses to flip it
  silently on an app that already has a `db/schema.rb`.
- **`attach_audit_trigger` is not idempotent, and the trigger name is
  `#{table}_audit` — derived from the table alone, ignoring `model:` and
  `exclude:`.** A second attach fails (`42710`, "trigger already exists") instead
  of succeeding, and that collision is the protection: a name carrying the model
  or the exclusion list would let two triggers coexist on one table and write two
  `audit_changes` rows per change under different exclusion sets. Do **not**
  reach for `CREATE OR REPLACE TRIGGER` (PG 14+, works on 18.6) to smooth this
  over — it would silently absorb a second attach carrying a *different* model or
  exclusion list, which is the one case worth hearing about. `detach_audit_trigger`
  **is** idempotent (`DROP TRIGGER IF EXISTS`); detach-then-attach in one
  migration is the supported way to change a table's exclusions or model name,
  and it is not retroactive — rows already written keep their diffs.
- **Attaching to a table that already exists is fine**, and the "in the migration
  that creates it" wording is a review convention, not a requirement — the helper
  is a bare `CREATE TRIGGER` that reads nothing from the `create_table` beside it,
  and `coverage_spec` queries `pg_trigger`, not the migration history. The real
  constraint is the table's shape: the trigger function assigns
  `rec_id bigint := NEW.id`, so an `id: false` join table, a `uuid` primary key or
  a PK not named `id` **fails on the first write after attaching**, not at
  migration time. See "Attaching to a table that already exists" in
  `README.md`.
- **`AuditLog::TransactionStamp` prepends `raw_execute`, not
  `begin_db_transaction`.** This looks like a hot-path mistake and is not.
  Transaction-start stamping misses `update_all`/`delete_all`/raw SQL, which open
  no transaction, so those writes land with a NULL actor. Read the comment at the
  top of `lib/audit_log/transaction_stamp.rb` before touching it. It also clears
  its per-connection memo on rollback — that is load-bearing, not defensive.
- **`AuditLog::Record#readonly?` returns `persisted?`, not `true`.** A flat
  `true` makes `create_or_update` raise on **inserts**, which breaks the event
  subscriber and silently disables all of layer 2.
- **`Rails.event.raise_on_error = true`** in the engine initializer.
  `ActiveSupport::EventReporter` otherwise swallows subscriber exceptions, which
  would mean a failed audit write vanishes while the change rows it describes
  commit anyway.
- **`self.enqueue_after_transaction_commit = true` is set on the job class.**
  `config.active_job.enqueue_after_transaction_commit` in `application.rb` is
  explicitly filtered out by ActiveJob's railtie and does nothing.
- **The job origin is captured in `serialize`, not `around_enqueue`.**
  `perform_all_later` and Solid Queue's `enqueue_all` skip enqueue callbacks.
- **A nil actor stores `NULL`, never the string `"System"`.** The UI renders
  "System" at display time. Storing it would make a console session
  indistinguishable from a genuine scheduled action.
  `AuditLog::ActorLabel.display` is the ONE definition of that fallback chain,
  and `.linkable?` says whether there is an actor to link to. A screen must not
  re-spell either: a `GROUP BY` rollup hands the view a **tuple**, not a record,
  so `actor_display` is unavailable there, and the hand-rolled copy on
  `actions/show` dropped the nil branch and then `actor_path(nil)` raised
  `UrlGenerationError` — taking the entire screen down the first time an
  actorless action (`audit.redaction`, whose rake task passes no actor) was
  rolled up on it. Use `audit_actor_cell`.
- **Association labels in a diff are resolved LIVE at display time, and that does
  not contradict `ActorLabel`'s snapshot rule — it depends on it.** An actor label
  *replaces* the identity in its column, so a live join there would let a rename
  rewrite what the log says happened; an association label sits *beside* the id
  that was recorded. **The id is never dropped** — `Grommet 10mm (id: 51)`, never
  `Grommet 10mm`. Rendering only the label is the one change here that would turn
  an audit screen into a report of current state. Nothing the label chain returns
  is ever stored: storing an honest as-of-then label means looking it up in the
  trigger, which is N `SELECT`s on every audited write. DESIGN §11.8.
- **`AuditLog::RecordLabel`'s chain ends in `nil`, not in `"Product #51"`** — the
  other place it deliberately differs from `ActorLabel`, whose chain must end in
  something because its column would otherwise be blank. Here the id renders
  unconditionally, so a model with no hook must produce no label and leave the cell
  byte-identical to before the feature existed. That nil ending *is* the opt-in.
  The chain is `to_audit_label` → `to_label` → a deliberately overridden `to_s`,
  and **there is deliberately no `name`/`title` column sniffing** — guessing which
  column reads as a label is how a screen confidently captions an id with the wrong
  string. Adding a sniffing fallback, or a `"Type #id"` terminal, both look like
  improvements and are the two ways to break this.
- **Foreign-key discovery is `belongs_to` reflection, never a naming convention.**
  `orders.created_by_id` points at `User`; de-suffixing and classifying the column
  gives `CreatedBy`, which does not exist. `config.association_targets` covers what
  reflection cannot see (`false` suppresses a column). The reflected map is
  memoized **per request and never at process level** — it holds host-app class
  names, which a code reload would leave stale.
- **A diff cell has four distinguishable outcomes and they must stay that way:**
  resolved, `(not found)` (the row was deleted — information, not an error),
  `(label unavailable)` (the lookup broke — *not* the same as never having asked),
  and the bare id. `LabelResolver` accordingly treats a resolver returning `nil`
  ("I do not label this type") differently from `{}` ("I do, and none of those ids
  exist"): collapsing them prints `(not found)` against every id of an un-opted-in
  model and announces deletions that never happened. A raising resolver is logged
  and rendered as FAILED, never re-raised — the `actor_path(nil)` lesson. The
  Record identity cell deliberately does *not* surface `(not found)`, because a
  record its own row deleted is gone by definition.
- **`audit_labels.warm` is an optimization, not a correctness requirement.** A miss
  resolves on demand, so a screen that forgets to warm is slower and never wrong.
  Do not restructure it into something a new screen can silently skip. **CSV export
  is deliberately unlabelled** — it is the evidence artifact and ships recorded ids.
- **`AuditLog::Timeline` is a PUBLISHED CONTRACT host apps render, not an
  internal query object.** Its value objects (`Activity`, `FieldChange`,
  `TouchedRecord`, `Actor`) exist because the auditor screens encode rules that
  are invisible from outside the gem — the three nil shapes of a diff value, the
  nil-actor fallback, the redaction marker, the four `LabelResolver` outcomes,
  the never-drop-the-id rule. Handed a relation, every host app re-derives those
  and some get them wrong on a screen that looks fine. Changing a method name or
  a return shape here breaks apps you cannot see. DESIGN §11.2b.
- **`Activity#headline` returns nil when no registered action covered the write,
  and that nil is the contract — do NOT add a generated sentence.** A phrasing
  composed from column names would be this gem's wording rather than the app
  author's, would re-render differently after a gem upgrade, and — the part that
  matters — would be indistinguishable on the page from a `summary` frozen at
  emit time, which is immutable history. Same discipline as `RecordLabel`'s chain
  ending in nil. The host has i18n, knows its model names, and may have STI names
  the gem could never guess; it gets `operations`, `record_type` and
  `changed_columns`. `kind` (`:narrative` / `:change_only`) says which it holds.
- **The timeline's index is a UNION over both tables, keyed on the unit of work,
  and that key must be ONE non-null text column.** `COALESCE(request_id::text,
  'row:' || id)` — an out-of-band write has no `request_id` and each one is its
  own unit, so a synthetic key stops every uncorrelated write in the log
  collapsing into one NULL group. Keying on `(request_id, id)` instead, with a
  NULL in one of the two on every row, makes the row-wise keyset predicate
  evaluate to NULL and the whole timeline goes blank after page one, silently.
  That is the same NULL trap as `where.not(subject_type:, subject_id:)` in
  `RecordTimeline` — it has now bitten this feature twice, in two disguises.
- **The events leg of that union is not optional.** Without it the timeline drops
  an action that wrote only children (a line item added to an order that itself
  did not change), one whose write landed in another table, one that wrote
  nothing, and EVERY action on a record whose table is in `unaudited_tables` —
  which has no trigger, so a changes-only index renders an empty page for a
  record with a full narrative history. What it still does not reach is an
  *unregistered* child-only write, and that is a registry gap for
  `audit_log:reconcile`, not something to chase through a child's foreign key: it
  would need a live join to a business table, which is what keeps these screens
  truthful about deleted records. DESIGN §11.2b.
- **`AuditLog::Pagination` is part of the PUBLISHED contract, not an engine
  internal.** A host app rendering a timeline includes it, and that is the
  documented path: a hand-rolled keyset pager over `activity_keys` serialises the
  cursor at ActiveSupport's default millisecond precision while `occurred_at` is
  microsecond `clock_timestamp()`, so rows vanish between pages, silently, as a
  rare flake. `FULL_PRECISION` is the whole reason the module exists — do not
  narrow it to `AuditLog::ApplicationController`, and do not let the README go
  back to suggesting "any keyset pager".
- **`ActivityKey` and `Activity` are the same thing at two stages of loading, and
  the split is forced rather than chosen.** `ActivityKey` is the identity (which
  unit of work, and when); `Activity` is that with the events, change rows and
  labels loaded. Pagy needs a RELATION to mint a cursor, so what comes out of
  pagination must be an ActiveRecord object; hydration must be batched (three
  queries a page, not three an activity); and Rule 2 keeps the limit above the
  controller, so the library cannot paginate and hydrate in one call. Do not
  "simplify" this into one type — that means making `Activity` an
  `ActiveRecord::Base`, which drags `.where`/`.find`/`save` into a published
  contract and leaves an unhydrated `Activity` answering `headline` with nil.
  `ActivityKey` has NO `as_json` on purpose: it is a handle to hand back, not
  content to render.
- **`Timeline::ActivityKey` has three requirements that all look like clutter and
  are not.** (1) `table_name` must be a REAL table and the subquery must alias to
  that same name, or ActiveRecord raises `PG::UndefinedTable` just loading the class — and `occurred_at` must be a typed timestamptz or Pagy
  cannot render the cursor at microsecond precision, which is the
  `FULL_PRECISION` bug all over again. (2) `attribute :key, :string` declares the
  synthetic column. (3) Callers must order with `arel_table[:key]`, never
  `order(key: :desc)` — a non-column name renders as an `Arel::Nodes::SqlLiteral`
  and `Pagy::Keyset#extract_keyset` calls `.name` on it. `timeline_spec` pins all
  three, so an upgrade that breaks one fails a spec rather than a screen.
- **One unit of work is one activity, so there is deliberately NO page-boundary
  rule.** An earlier changes-only index paged over change *rows* and grouped them,
  so a unit could straddle a cursor and needed a de-duplication pass. Keying on
  the unit itself deleted that problem. Do not reintroduce row-level paging
  here "for simplicity" — it costs a de-dup pass and buys nothing.
- **`Timeline` is unbounded by default and there is deliberately no config-level
  default bound.** A bound nobody asked for is invisible truncation. `range:`
  goes INSIDE each leg (on the outer aggregate the planner cannot push a
  predicate on `max(occurred_at)` back through the `GROUP BY`, so it prunes
  nothing), it must be bound as Ruby Times and never as SQL — `now() - interval`
  prunes at RUN time, after the planner has opened all 72 partitions — and an
  endless range is closed at `Time.current`, which is safe because
  `clock_timestamp()` cannot produce a future row and is worth 3x. Measured:
  72 partitions unbounded, 4 at `30.days.ago..Time.current`.
- **`older_than_window?` is opt-in and must never be called from `#activities`.** It
  deliberately looks below `range.begin` — the one thing the bound exists to
  avoid — so calling it per page hands back the pruning the caller just bought.
- **`config.record_url` defaults to nil and the default is not a placeholder.**
  Inferring `product_path` from `"Product"` is the same mistake as sniffing a
  `name` column for a label, and it fails at render time on a screen an auditor
  is reading. Silence is the opt-out. It serves actors too — an actor is a record,
  so there is deliberately no second `actor_url` lambda.
- **`TouchedRecord#to_s` keeps the id and must go on doing so.** `Grommet 10mm
  (Product #51)`, never `Grommet 10mm`. The label is resolved live from current
  state; the id is what the log recorded (DESIGN §11.8). A host building a pretty
  timeline will want to drop it, which is exactly why the pretty method is the
  one that keeps it.
- **The Timeline card renders `metadata` in the SAME three states as
  `shared/_event_payload`, and the redaction note is not inside the
  `<details>`.** The first version of the card had only
  `if activity.metadata.any?`, which renders a redacted activity — whose metadata
  was emptied — as nothing at all: the card picked up its warm tint and said
  nothing about why. That is the silent hole redaction exists to avoid, in a new
  screen. `Activity#redacted?` is the discriminator and reads through
  `Redaction.marker?`; the note precedes the field changes, because it explains
  the `[redacted ...]` values below it.
  `audit_ui_spec` asserts the note is outside every `<details>` on the page, not
  merely present somewhere.
- **The engine's Timeline tab renders the value objects, not relations.** That is
  the dogfooding: a presenter nothing in the gem consumes drifts from what the
  auditor UI actually does — the same argument that makes one `Coverage` back both
  the rake task and the shared example. Do not "simplify" it back to rendering
  `AuditLog::Change` directly.
- **Authorization is deliberately absent from `Timeline`.** The gem exposes
  everything and the host gates it: "admins only" is a policy question about the
  host's roles that no config lambda here would express better than the host's
  own authorization layer. `config.authorize` gates the auditor UI; a
  host-rendered timeline is the host's screen. Do not add a half-policy here.
- **The record history screen has two tabs, and the narrative one has two
  SECTIONS that must not be merged.** `AuditLog::RecordTimeline#events` is the
  actions that named this record as their `subject` (indexed, uncapped);
  `#correlated` is the actions that wrote to it without naming it, found by
  matching `request_id` against the record's own change rows. Merging them into
  one list reads better and makes two false claims: that an action which happened
  to touch this record is the same as one that was about it, and that the whole
  list is as complete as the top half. Only `correlated` is capped, and it prints
  `scanned` / `truncated?` for exactly that reason. DESIGN §11.2a.
- **`where.not(subject_type: t, subject_id: i)` is the WRONG exclusion in
  `RecordTimeline` and fails silently.** It compiles to
  `NOT (subject_type = t AND subject_id = i)`, which is NULL — and therefore
  excludes the row — whenever `subject_type IS NULL`. An action registered with no
  `subject:` lambda is that row, and it is the single most important thing the
  correlated section exists to surface, so the natural spelling drops the entire
  population the feature is for while the screen still renders fine. It is spelled
  `(subject_type, subject_id) IS DISTINCT FROM (?::text, ?::bigint)`, which is
  null-safe in both columns; `record_timeline_spec` pins it.
- **`AuditLog::Record.grouped_by_request` is date-bounded, and that bound is not
  optional.** It lives on the shared base, not on `Change`, because both tables
  carry `request_id` and `occurred_at`: a page of events hydrates its changes and
  a page of changes hydrates its events through one implementation. `WHERE request_id IN (...)` names `occurred_at` not at all, so the
  planner eliminates no partition — the same argument `RequestDrillDown`'s
  doc-comment makes at length. The window comes from the page's own events, so it
  infers nothing. This is ONE method because the actor screen and the record
  timeline both need it and an earlier hand-rolled copy on `ActorActivity`
  carried no bound at all — the one drill-down in the library that scanned every
  partition on every page render.
- **`caused_by_request_id` is a real indexed column on `audit_events`, not a
  `metadata` key.** It points at a *different* unit of work than `request_id` (the
  request that enqueued this job) and the two are never equal on a row. It was
  moved out of `metadata` because the "what did this cause?" query had no index
  and scanned every partition, and because `metadata` is the action's own payload
  — an action carrying that key silently overwrote the framework's. Partial index,
  since only job-originated events have a cause.
- **The drill-down is date-bounded, and the bound comes from the `request_id`
  itself.** `WHERE request_id = ?` prunes no partitions, so
  `AuditLog::RequestDrillDown` anchors on an event's `occurred_at` when it has one
  and otherwise decodes the UUIDv7's embedded mint timestamp
  (`AuditLog::Context.minted_at`). `minted_at` returns `nil` for a v4 id on
  purpose — decoding random bits gives a plausible timestamp and a silently empty
  screen. The window is generous (`config.drill_down_slack`, 24h), disclosed in
  the UI, and escapable with `?full=1`, because a bound that under-reports is
  worse than a slow query. **Seeds must keep `request_id` consistent with
  `occurred_at`** — backdating one without the other empties the screen; seeds use
  PG 18's `uuidv7(shift)`.
- **Everything about time in the audit tables is UTC, and two separate
  mechanisms keep it that way.** (1) *Stored values*: `occurred_at` is
  `timestamptz` filled by the column `DEFAULT clock_timestamp()`; neither layer
  supplies it from Ruby, so `config.time_zone` cannot reach it. Adding
  `occurred_at:` to `EventSubscriber#emit` or to the trigger's `INSERT` breaks
  this silently — `spec/audit_log/utc_storage_spec.rb` asserts against both source
  files. (2) *Partition boundaries*: `create_month!` pins `+00` in the DDL literal
  because a bare date is resolved against the session `TimeZone` at DDL time, and
  the month arithmetic uses UTC rather than `Date.current`. `misaligned_bounds` /
  `rake audit_log:partitions` report violations. `ENV["PGTZ"] ||= "UTC"` in the
  engine only makes `pg_dump` render those bounds as `+00` instead of a rotating
  local offset.
- **`AuditLog::DateRange` is deliberately NOT UTC** — it builds bounds in
  `Time.zone` because a date filter is a human's calendar day. The cost is that an
  app-zone range crosses a UTC month boundary and touches one extra partition. A
  known `+1`, not a bug. Do not "fix" it by moving the partition boundaries into
  the app zone; a DST-observing boundary overlaps or gaps twice a year.
- **`changed_columns text[]` + GIN, and deliberately no GIN index on `diff`.** A
  `jsonb_path_ops` index does not support the `?` operator at all and silently
  degrades to a seq scan.
- **The "payload redacted" note is NOT inside a `<details>`, while the payload
  itself is.** `audit_events.metadata` is rendered by
  `shared/_event_payload` in three states, and the asymmetry is the point: an
  emptied payload and an action that carried none are the same empty jsonb, so
  collapsing the redaction notice hides the one thing that distinguishes an
  erasure from an absence. The discriminator is `AuditLog::Redaction.marker?` —
  redaction leaves no flag column by design, so the marker string is the only
  trace. Do not re-spell that regex in a view; `redaction_spec` matches
  `marker?` against `marker_for` so the two cannot drift.
- **Payload values render untruncated, via `audit_metadata_value` and not
  `audit_value`.** `audit_value` truncates, which is correct for a diff cell in a
  wide table and wrong for `metadata` — it is the structured evidence behind the
  summary sentence, and an ellipsis in it is the screen under-reporting silently.
  CSS wraps long values instead.
- **`AuditLog::Redaction` is the ONLY thing permitted to modify audit rows.**
  Everything else treats them as append-only (`readonly? = persisted?`). It uses
  raw SQL by necessity and by design, it never touches `changed_columns` — the
  structural record is what survives an erasure request — and it writes its own
  `audit.redaction` event inside the same transaction. Do not add a second
  mutation path, and do not "simplify" it by deleting rows.
- **`audit_log:redact` takes `FIELDS=`, never `COLUMNS=`.** `COLUMNS` is a
  reserved shell variable holding the terminal width, so it silently arrives as
  a number, matches nothing, and redacts nothing while reporting success.
- **Only `audit_log:partitions` belongs in a cron.** `drain_default`, `rollup`
  and `retention` each take `ACCESS EXCLUSIVE` on an audit table, which blocks
  every audited write in the application. They run under
  `config.maintenance_lock_timeout` (5s) so they fail fast rather than queueing —
  a pending `ACCESS EXCLUSIVE` request blocks every lock behind it, so an
  unbounded wait behind one long reader stalls the write path.
- **`with_maintenance_lock` wraps its advisory-lock calls in
  `connection.uncached`.** `pg_try_advisory_lock` is a `SELECT` with a side
  effect, so ActiveRecord's query cache treats it as an ordinary read: acquire,
  release, acquire again with no intervening `execute` and the second acquire is
  served from the cache as `true` while `pg_locks` shows the session holds
  nothing. Removing `uncached` leaves the method *reporting* mutual exclusion it
  is not providing. Everything else here mutates through `execute`, which does
  invalidate the cache — including the drain's `DELETE`, which is deliberately
  `execute` rather than `select_value` for exactly that reason.
- **The three maintenance operations take a session advisory lock so they cannot
  overlap.** `drain_default!` reinserts relocated rows under their *original*
  ids, which are below any watermark taken later — so a drain landing a row in a
  monthly partition midway through a rollup would slip past `id > watermark` and
  be dropped with that partition. Rollup phase 1 holds no lock on the parent, so
  the interleaving is reachable. Advisory locks are re-entrant within a session,
  so this serialises *sessions* (two rake tasks, a cron overlapping a console),
  which is the case that matters.
- **`rollup_year!` stamps a table comment (`ROLLUP_MARKER`) on its staging table
  and never uses `DROP TABLE IF EXISTS` on the target.** An unattached
  `audit_events_2019` is either this library's debris from an interrupted run —
  safe to recreate — or a table somebody else made, where dropping it destroys
  data. Only the marker tells them apart. `orphaned_rollups` reports the debris,
  because a staging table is not a partition and nothing else would ever mention
  it while it holds a full year of audit data.
- **`retire!` and `rollup!` yield each result as it commits.** Each partition is
  its own transaction, so a failure on the fifth leaves four already retired; a
  caller that only reads the return value learns nothing about those four.
- **There is no `ALTER TABLE ... MERGE PARTITIONS` in PostgreSQL.** The patch was
  reverted before 17 shipped and is absent from 18 (verified against 18.6).
  `rollup_year!` is therefore a hand-rolled copy-and-swap, staged so the
  exclusive lock covers catalog work only. Its id-watermark check is read
  **before** the copy, not after: a watermark read after would not catch a row
  that landed during the copy, which is exactly the row that would be lost.
- **`retention_action` defaults to `:detach`, and retired partitions keep their
  data under a `_retired_` name.** Detaching is reversible with one `ATTACH`;
  dropping seven-year-old audit data is not. `rake audit_log:partitions` reports
  detached leftovers with their size so they cannot accumulate unseen. The rename
  also stops `create_month!` mistaking a retired table for a live partition.
- **`expired_partitions` keys on the UPPER bound**, never the lower — the lower
  bound would retire a month that still holds in-horizon days. Same reasoning
  makes `freeze_closed!` read real bounds rather than parse the name, which is
  also what makes it cover yearly partitions for free.
- **Retention, rollup and lock-timeout keywords default to `AuditLog.config.…`
  in the method signature, not via `||=`.** `||=` cannot distinguish "not passed"
  from an explicit `nil`, and an explicit `nil` is how a caller says *disabled*.
- **`drain_default!` stages rows through a temp table.** A partition covering a
  range cannot be created while the default partition holds rows in it, so the
  rows must come out before the partition can go in. One transaction, so a
  failure leaves them where they started. It computes the target month with
  `date_trunc('month', occurred_at AT TIME ZONE 'UTC')` — `date_trunc` on a bare
  `timestamptz` truncates in the session zone and files boundary rows wrong.
- **Yearly rollup coarsens retention by design.** A yearly partition can only be
  retired whole, so up to eleven extra months are kept past the horizon. That is
  the trade `rollup_after` (2 years) exists to bound; do not roll up warm years.

Every browse screen is keyset-paginated through `AuditLog::Pagination`
(DESIGN §11.0 Rule 2). **Do not add `.limit` to a screen's scope** — a limit
baked below the controller is invisible to the page rendering it, which is
exactly how an audit view comes to under-report without saying so. The dashboard
is the deliberate exception: its lists are "10 most recent" widgets, not
browsable results. `config.page_size` is the only knob.
- **`AuditLog::Pagination::FULL_PRECISION` is load-bearing.** Pagy serializes the
  keyset cursor with `to_json`, and ActiveSupport renders a `Time` at
  `time_precision` **3** — milliseconds — while `occurred_at` is
  `clock_timestamp()`, microseconds. Without the lambda the cursor names an
  instant just before the row it came from and the next page silently skips
  everything in the gap. It presents as a rare flake, not as an error.
  `spec/audit_log/pagination_spec.rb` pins it with six rows inside one
  millisecond; that example returns 2 of 6 rows if the lambda is removed.

## The activity generator

`rails generate audit_log:activity Order Product Customer` emits the reference
app's timeline UI into a host app. Four things about it are load-bearing:

- **The templates ARE the reference app's files.** `../audit-log-demo` is
  regenerated from them and differs by exactly one line — its
  `audit_activity_visible?` returns `current_user&.manager?` where the template
  returns `false`. Change a template, regenerate the demo, run its suite. Two
  hand-maintained copies is the failure this arrangement exists to prevent.
- **View templates emit ERB THROUGH ERB.** Every runtime tag is escaped `<%%`,
  and only the class slots (`<%= css(:card) %>`) are generate-time. Get it wrong
  and you ship a view that renders its own source, which reads as a styling bug.
  `activity_generator_spec` compiles every generated `.erb` and asserts no `<%%`
  survives.
- **`audit_activity_visible?` is generated as `false`.** Never change that to
  `true` "for convenience". It is the difference between a host that has decided
  who may read audit diffs and one that has published them by default.
- **The show-page wiring guesses NOTHING it cannot verify.** It injects
  `recent_activity(@order)` into `#show` and the render into the view only when
  the controller has a bare `def show` AND already mentions `@order`; otherwise
  it declines and prints the lines. A wrong ivar renders an EMPTY feed rather
  than raising, which reads as "the audit log has no data" — the quiet
  under-report this library exists to prevent, arrived at through a generator.
- **A second run is create-once, not overwrite.** It updates
  `ActivityController::VIEWABLE` and leaves every file alone, because adding a
  model six months later runs against files the host has since edited. Before
  this, `--force` silently reverted an edited `audit_activity_visible?` — which
  reopens a history to everyone and reports nothing — and without `--force` Thor
  blocked on an interactive overwrite prompt. `--force` still overwrites, for
  deliberate re-baselining; that is how the reference app is regenerated.
- **`--css` changes `class=` and NOTHING else.** The spec asserts the three
  frameworks produce byte-identical markup once class attributes are masked. If a
  framework needs different structure, the abstraction is wrong — fix the
  structure, do not fork the template.

## Things that look DEAD and are not

A grep for callers marks all of these unused. Audited 2026-08-29 — 163 public
methods, 3 genuinely dead and removed (`ActionReport.available_actions`,
`Current#correlated?`, `Event::SOURCES`). Everything below survived that pass on
purpose, so do not re-run the audit and delete them.

| Looks unused | Actually |
|---|---|
| every public method in `lib/generators/` | Thor invokes each one as a generator step; naming them is the API |
| `TransactionStamp#exec_rollback_db_transaction` / `#exec_rollback_to_savepoint` | ActiveRecord adapter hooks. Clearing the per-connection memo on rollback is load-bearing — see the entry above |
| `JobContext#deserialize` | an ActiveJob hook |
| the six controllers in `app/controllers/` | routed by `config/routes.rb`, so no source file names the constant |
| `detach_audit_trigger` | published migration API; detach-then-attach is the supported way to change a table's exclusions |
| `Redaction.redact_actor!` | a documented capability (DESIGN §13), reachable from a console rather than a rake task |
| `RecordLabel.labelable?` / `.overridden_to_s?` | called inside `record_label.rb` itself |
| `Timeline::FieldChange#association?`, `TouchedRecord#label_failed?`, `Actor#system?` | the published host-facing contract — a host renders these, this gem does not have to |

**Two are kept for symmetry and that is a real reason.** `Change#updated?` and
`Timeline::Activity#change_only?` are each the unused third of a set whose other
members are used. A model answering `created?` and `deleted?` but not `updated?`
is a surprise somebody re-adds within a month, and the re-adding is more churn
than the three lines cost.

**And one that looked dead was the opposite.** `Change#operation_name` had no
callers because a refactor had inlined `OPERATION_NAMES.fetch(op, op)` into three
places instead. Deleting it would have removed the one thing that should have
been shared; it is now a class method both helpers call. When something in this
library has no callers, check whether the thing it encapsulates has been copied
rather than dropped.

## Adding a model (what a host app does)

Nothing goes in the model class — no concern, no callback, no base class. The
per-model cost is one line in the migration:

```ruby
create_table :widgets { |t| ... }
attach_audit_trigger :widgets, model: "Widget"
```

That is the pattern for a *new* table. An **existing** table can be attached from
a standalone migration just as well, and changing a table's exclusions is
detach-then-attach — see the two `attach_audit_trigger` entries above and
"Attaching to a table that already exists" in `README.md`.

If a table genuinely should not be audited, add it to
`AuditLog.config.unaudited_tables` **with a written reason**. Anything else fails
`rake audit_log:coverage` and the shared example this gem ships:

```ruby
# spec/audit_log/coverage_spec.rb, in the host app
require "audit_log/rspec"

RSpec.describe "audit trigger coverage" do
  it_behaves_like "an app with complete audit coverage"
end
```

Both go through the one `AuditLog::Coverage`, so they cannot disagree about what
counts as covered. That is the forcing function and it is intentional — do not
weaken it to make a build pass, and do not copy the examples into a host app
where they can drift from the rule this library defines.

Adding a *narrative* action also needs an `AuditLog::Registry.register` entry in
the host app's `config/initializers/audit_log.rb`. Skipping it is legal: the change is still
fully audited at the record level and simply shows up in the completeness
reconciler, which is how the registry keeps filling in.

## Tasks

Registered by the engine, so they appear in any host app's `rails -T`. From this
gem, run them inside the dummy app (`cd spec/dummy`).

```bash
bin/rails audit_log:coverage           # fail if a table lacks a trigger and a reason
bin/rails audit_log:partitions         # create missing months; warn on overflow and retired leftovers
bin/rails audit_log:drain_default      # relocate rows stranded in the default partition
bin/rails audit_log:rollup             # consolidate closed years into yearly partitions (DRY_RUN=1)
bin/rails audit_log:retention          # detach/drop partitions past the horizon (DRY_RUN=1)
bin/rails audit_log:export DIR=…       # stream retired partitions to gzipped CSV + manifest
bin/rails audit_log:drop_exported DIR= # drop only partitions whose export verifies
bin/rails audit_log:freeze             # VACUUM FREEZE closed partitions
bin/rails audit_log:reconcile          # correlated changes with no registered action
bin/rails audit_log:benchmark ROWS=n   # generate volume, EXPLAIN the canonical queries
bin/rails audit_log:benchmark_cleanup  # remove the synthetic rows
```

`audit_log:benchmark` writes synthetic rows into the real audit tables. Run it
against a scratch database or clean up after. Drive any new benchmark query
through the library's own query objects — an earlier version hand-rolled
relations, dropped the `ORDER BY` the app actually applies, and reported a 48 ms
seq scan for a query that really runs in 0.8 ms.

## Working on the library

Two loaders, and only one of them reloads:

| Path | Loader | Reloads? |
|---|---|---|
| `app/**` (controllers, views, helpers, models, queries, timeline value objects) | Zeitwerk, via the engine | **yes** |
| `lib/audit_log/*.rb` | `Kernel#autoload` from `lib/audit_log.rb` | **no** — once per process |

**Restart after editing anything under `lib/audit_log/`** — `configuration.rb`,
`context.rb`, `partitions.rb`, `record_label.rb`, `schema.rb`,
`transaction_stamp.rb` or any other top-level file — or you get a reloaded query
object calling a stale `Configuration`, which `AuditLog.config` memoizes besides.

This applies to a host app consuming the gem by path too: `../audit-log-demo`
picks up an `app/**` edit on the next request and a `lib/**` edit only on
restart.

Two constants worth knowing when moving files: `AuditLog::GEM_ROOT` (the gem
root, used by `Schema::SQL_DIR` and the generators — deliberately not
`Engine.root`, because `Schema.install!` is called from a migration and must not
require a booted engine), and the `__dir__`-relative `rake_tasks` load in
`engine.rb`. `Engine.find_root` was **deleted** in the extraction: it existed only
to stop Rails' root-walk resolving to the host app while the library lived inside
one. Do not reintroduce it.

## Testing

```bash
bundle exec rspec                         # 308 examples, against spec/dummy
bundle exec rspec spec/audit_log          # the library proper
bundle exec rspec spec/requests           # the auditor UI and the CSV export
bundle exec rspec spec/preview.rb         # dev tool: renders 17 screens to spec/dummy/public/
```

`spec/preview.rb` is deliberately not `_spec.rb`, so it is not auto-collected.
It renders the **engine's** screens only; the reference app keeps its own copy
that also renders its order/product/customer pages, because those consume this
library's query objects and are what a signature change actually breaks.

`spec/dummy` has no Devise, no password column, no Solid Queue and one database.
That is the enforcement mechanism for "the one rule that matters most" — see
above. Do not add a gem to the dummy app to make a spec easier; that is the spec
telling you the library has grown a coupling.

When changing the library, the specs that matter most all assert the same
property from different angles — **that nothing goes missing without saying so**:

| Spec | What must not happen |
|---|---|
| `coverage_spec` | a table escapes the audit/exempt decision |
| `completeness_spec` | a callback-bypassing write path is not captured |
| `job_correlation_spec` | a job loses its actor or its cause |
| `pagination_spec` | a row vanishes between pages |
| `audit_csv_spec` | an export stops short of the range it claims |
| `archive_spec` | a partition is dropped without a verified export |
| `redaction_spec` | redaction removes structure, not just values |
| `association_labels_spec` | a label replaces a stored id, or a failed lookup reads as an absent one |
| `record_timeline_spec` | an unsubjected action vanishes from a record's narrative, or a capped section does not admit it is capped |
| `timeline_spec` | the published host-facing contract changes shape, a unit of work is dropped or repeated across pages, an event that wrote no change row falls off the timeline, or `headline` starts inventing sentences |
| `install_generator_spec` | the ControllerContext include lands ahead of authentication, or a skipped step reports success |

A change that makes any of those pass *more easily* is a regression.

Two testing traps already hit here:

- **The `:job` tag is only a label here.** `spec/dummy` configures the ActiveJob
  test adapter outright, so nothing needs swapping. The reference app *does* need
  an around-hook, because it deliberately runs real Solid Queue in test — if you
  copy a job spec from there, do not copy the hook with it.
- **RSpec runs with the ActiveRecord query cache OFF; web requests, jobs and
  `rails runner` run with it ON.** A statement that is a `SELECT` but has side
  effects behaves differently in the two, and the suite will not tell you. The
  guard for this is `partition_lifecycle_spec.rb`'s "acquires a real lock even
  with the query cache enabled", which wraps the example in `conn.cache`. Note
  that it exercises `retire!` with nothing expired specifically because that path
  issues no `execute` — routing the same test through `drain_default!` passes
  either way, since its DDL invalidates the cache and hides the bug.
- **Do not assert that a specific index was chosen** in a query plan. On a small
  test database the planner correctly picks a seq scan regardless, and
  `enable_seqscan = off` only proves *some* index was used. Assert partition
  pruning from the plan and index definitions from `pg_indexes`; leave
  plan-shape-at-volume to `audit_log:benchmark`.

## CI

`.github/workflows/ci.yml`, on every push and pull request. It exists because the
forcing functions above force nothing if they only run when someone remembers.

Two parallel legs, and the pairing is deliberate:

| Leg | Why |
|---|---|
| Ruby **3.3** | the floor `required_ruby_version` claims. Testing only the development Ruby leaves that claim unverified — and it *was* wrong: the gemspec said 3.2 until this leg failed on `SecureRandom.uuid_v7` being 3.3+. |
| Ruby **4.0.6** | what the library is developed on |

If the floor leg fails, the honest responses are to fix the code or **raise the
floor**. Dropping the leg is not one of them.

Three things about it are load-bearing rather than boilerplate:

- **A PostgreSQL 18 *client*, not just an 18 server.** The runner image ships
  `postgresql-client-16`, and `pg_dump` refuses to dump a newer server. That is
  not a CI detail here: `schema_format = :sql` puts `pg_dump` on the ordinary
  migration path, and the engine's `PGTZ` initializer exists to control what it
  renders. Both server and client versions are asserted, separately, because they
  fail differently.
- **`db:create db:migrate`, never `db:prepare`.** `db:prepare` seeds a database it
  had to create. `spec/dummy` has no seeds, but the reference app does, and there
  `db:prepare` collided on a seeded email and would have silently changed what
  row-counting specs measure. Use `db:test:prepare` in an app that has seeds.
- **`gem build` must be warning-free, and `LICENSE.txt` must be inside the
  packaged gem.** `gem build` is the only packaging step this proprietary gem ever
  runs. The warning gate has already earned its keep: it caught the open-ended
  `rails >= 8.0` dependency, and only on the 3.3 leg, because that rubygems is
  stricter than 4.0.6's. If a future rubygems adds an advisory warning, fix the
  gemspec or consciously narrow the check — do not delete it.

**Unverified claim, deliberately left standing:** `rails ~> 8.0` admits 8.0, but CI
tests 8.1.3.1 only. The gap is the exact one the Ruby matrix closed, so expect a
Rails 8.0 leg to find something — `Rails.event` does not exist there, and
`AuditLog.notify`'s fallback path is consequently untested.

## Deliberately not implemented

Per [`DESIGN.md`](DESIGN.md) §12, §13 and `ROLLOUT.md` — all
decisions, not omissions:

- Database-level append-only enforcement (`REVOKE UPDATE, DELETE` + a rejecting
  trigger). Additive; needs `SECURITY DEFINER`, which complicates managed
  Postgres.
- Cryptographic tamper evidence. If ever added, do it as a nightly sealing job,
  never in the trigger.
- Read-access logging. Explicitly out of scope — this records changes, not views.
- Signed-PDF export. CSV is built; PDF was judged unnecessary for now.

Note the interaction with the first item: append-only grants would now need an
exception for `AuditLog::Redaction`, which is *supposed* to modify audit rows.

Two former entries are now built — **export of retired partitions**
(`AuditLog::Archive`) and **PII redaction** (`AuditLog::Redaction`). What is
still open about redaction is policy, not mechanism: who may authorize one, and
what makes a `REASON` valid.
