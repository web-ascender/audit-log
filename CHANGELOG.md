# Changelog

## Unreleased

### `rails generate audit_log:views:activity`  **[2026-08-29]**

The auditor UI at `/audit` is for auditors. This generates the *other* screen —
an activity history a host app renders on its own pages, for people who should
not hold the auditor role — as the reference app's implementation extracted into
templates.

```bash
rails generate audit_log:views:activity Order Product Customer --css=tailwind
```

Produces a controller, a concern, a helper, three views, a route, a locale file
and (for `--css=plain`) a stylesheet. What it produces is the host's: plain
Rails, no gem-side indirection, never re-generated or upgraded later.

**`--css=plain|tailwind|bootstrap` changes `class=` and nothing else.** The
markup structure is byte-identical across all three — asserted by masking class
attributes and comparing — so switching frameworks later is rewriting strings
rather than re-deriving the view. Neither framework option installs anything.

**It denies everyone until one method is edited.** `audit_activity_visible?` is
generated as `false` and the generator says so in red. `Timeline` exposes
previous values of every audited column and the other records each action
touched, which on a shared action can be another customer's row; defaulting to
visible would publish that to every signed-in user of an app whose roles this gem
cannot see, and nothing would report it. The same method serves the show-page
widget and the full page, so the two cannot disagree about who may read a
history.

**The models named become an allowlist checked BEFORE `constantize`**, because
`/activity/User/1` is a URL anyone can type. The generator refuses to run without
them rather than emitting an empty one and 404ing on every record.

**The templates ARE the reference app's files.** `../audit-log-demo` is now
regenerated from them and differs by exactly one line — its
`audit_activity_visible?` returns `current_user&.manager?`. That is the whole
point: two hand-maintained copies drift, and the app that consumes the templates
is the only thing that can catch it when they do. It caught one immediately —
`audit_activity_visible?` is a private controller method, so the section partial
raised `NoMethodError` until the concern exposed it with `helper_method`. Nothing
in the gem's own specs would have found that, because nothing in the gem renders
those views.

The install generator's initializer template now documents `config.record_url`,
which the generated UI uses for links.

323 examples, 0 failures.


### Dead code audit  **[2026-08-29]**

Every public method, class, constant, config attribute and view partial in the
gem, checked against both this repo and the reference app. 163 public methods,
11 candidates, 3 genuinely dead:

- **`ActionReport.available_actions`** wrapped `Registry.keys` in a method nothing
  called — `ActionsController#index` calls the registry directly. Its spec was the
  interesting part: it asserted a method the screen does not use, so it passed
  green while the real path went untested. Rewritten to assert the property the
  controller actually has: an action that is registered and has never been emitted
  still belongs in the picker, because one sourced from `audit_events` would hide
  exactly the actions an auditor is most likely asking about.
- **`Current#correlated?`** — no callers anywhere.
- **`Event::SOURCES`** — unreferenced *and wrong*. It listed `migration`, which
  nothing in this library ever writes; the values actually produced are `web`,
  `api`, `job`, `system` and `console`. No CHECK constraint behind it and nothing
  validating against it, so it was a list a host could read, believe, and build a
  filter from that would never match. Worse than merely unused.

**`Change#operation_name` looked like a fourth and was the opposite.** It had no
callers because an earlier refactor inlined `OPERATION_NAMES.fetch(op, op)` into
three places instead — this model, the gem's badge helper, and the reference
app's. Deleting it would have removed the one thing that should have been shared.
It is now a class method, since every caller holds a bare operation code rather
than a row, and both helpers go through it.

The audit's *negative* results are now recorded in CLAUDE.md under **"Things that
look DEAD and are not"** — Thor generator steps, ActiveRecord and ActiveJob
hooks, routed controllers, published API with no in-gem caller, and two
predicates kept for symmetry. A future pass would otherwise delete them.

### `AuditLog::Pagination` is host-facing  **[2026-08-29]**

Documented in the README, DESIGN §11.0 and CLAUDE.md as something a host app
`include`s, replacing a README line that suggested "any keyset pager". A
hand-rolled one gets ActiveSupport's default millisecond cursor while
`occurred_at` is microsecond `clock_timestamp()`, so rows vanish between pages,
silently, as a rare flake — every adopting application rediscovering the same
defect. The module also carries the mismatched-cursor fallback.


### The timeline reads both tables, and takes a date bound  **[2026-08-28]**

`AuditLog::Timeline` was anchored on `audit_changes` alone, which made it
complete for every **write** to a record and silently blind to four things — each
one an action that named the record and wrote no change row *to it*:

1. an action that wrote only children (a line item added to an order whose own
   row never changes — any aggregate root whose children change more than it
   does),
2. an action whose write landed in another table (`order.emailed` → `deliveries`),
3. an action that wrote nothing at all (`order.exported`),
4. **every** action on a record whose table is in `unaudited_tables` — no trigger,
   so no change rows exist, so the page came back empty for a record with a full
   narrative history. A category, not an edge case.

`Timeline#changes` is now `Timeline#activity_keys`: a union of the record's change
rows and the events whose `subject` is that record, grouped by unit of work. All
four are covered by that one leg.

**It also removed code.** The old index paged over change *rows* and grouped
them, so a unit of work could straddle a cursor and needed a de-duplication pass.
Keying on the unit itself deletes that problem rather than managing it — one unit
of work is one activity and cannot split.

**`range:` bounds both legs**, and is the biggest lever on cost. Measured with
`EXPLAIN` against a 36-month horizon, 72 monthly partitions across the two tables:

| Bound | Partitions in the plan |
|---|---|
| unbounded (the default) | 72 |
| `1.year.ago..Time.current` | 34 |
| `90.days.ago..Time.current` | 16 |
| `30.days.ago..Time.current` | 4 |

Three findings there are worth more than the 18×. **Pruning survives the union
and the `GROUP BY`** — that was the open question. **The lower bound is the
lever**: an upper bound alone is nearly useless (52 of 72), because history runs
backwards indefinitely. And **an endless range is closed at the current instant**,
which is worth 3× and loses nothing, because `occurred_at` is filled by
`clock_timestamp()` and no row can be future-dated.

The default stays unbounded and there is deliberately no config-level default: a
bound nobody asked for is invisible truncation. A bounded timeline discloses
itself through `bounded?` / `scope_description`, the way `requests/show` discloses
the drill-down's window, and the engine's tab offers `?days=` so both states get
rendered — a disclosure that never renders is a disclosure nobody has tested.
`older_than_window?` is opt-in and never called from `#activities`, because it looks
below the bound and would hand back the pruning the caller just bought.

Four things found building it, each of which fails quietly rather than loudly:

- **The unit-of-work key must be ONE non-null text column.**
  `COALESCE(request_id::text, 'row:' || id)`. Keying on `(request_id, id)` — with
  a NULL in one of the two on every row — makes the row-wise keyset predicate
  evaluate to NULL, and the timeline goes blank after page one with no error. The
  same NULL trap as `where.not(subject_type:, subject_id:)`, which is now twice
  this feature has hit it in a different disguise.
- **Bind Ruby Times, never SQL.** `now() - interval '30 days'` reported 12
  partitions in the plan and **60 subplans removed at run time** — the planner
  kept all 72. Only a literal timestamp prunes at plan time, which is where the
  relation locks are.
- **The bound belongs inside each leg.** On the outer aggregate the planner cannot
  push a predicate on `max(occurred_at)` back through the `GROUP BY`.
- **Pagy paginates the subquery, but only under three conditions** — a real
  `table_name` that the subquery aliases to, `attribute :key, :string`, and
  ordering through `arel_table` rather than a symbol. `ActivityKey` documents each
  and `timeline_spec` pins them, so a Rails or Pagy upgrade fails a spec instead
  of a screen.

The CSV export is unchanged and deliberately not this index: the timeline tab
ships the record's change rows, because a unit of work is a grouping this library
invented rather than something the database recorded.

**Naming.** The two host-facing types are now `Timeline::Activity` — one thing
that happened to a record, loaded and ready to render — and
`Timeline::ActivityKey`, its identity before loading. They are the same thing at
two stages, and naming the second one after the first is what makes that legible;
an earlier pass called them `Entry` and `UnitOfWork`, two unrelated nouns for one
concept, and before that `SpineRow` with a `uow` column — vocabulary from the
design discussion that never earned its place in an API host applications read.
*Unit of work* survives as the prose term for the grouping principle, which is
what it always described.

`ActivityKey` deliberately has no `as_json`: it is an opaque handle to paginate
and hand back, not content to render.


### A host-facing activity timeline  **[2026-08-28]**

The auditor UI is for auditors. `AuditLog::Timeline` is the other audience: a
host application rendering an "activity history" on its own `orders/show`, in its
own markup, for its own staff.

- **`AuditLog::Timeline.for(record)`** — a paginated list of **units of work**,
  not audit rows. A form submit that saves an order and forty line items is ONE
  activity, with the order's field changes on it and the forty line items beside it.
  `#activity_keys` is the ordered, unlimited index the caller paginates; `#activities(page)`
  turns a page into value objects with three queries regardless of page size.
- **Value objects, not relations: `Activity`, `FieldChange`, `TouchedRecord`,
  `Actor`,** each with `as_json`. This is the point of the feature. The auditor
  screens encode rules invisible from outside the gem — the three nil shapes of a
  diff value, the nil actor that renders "System" but is never stored that way,
  the redaction marker as the only trace of an erasure, `LabelResolver`'s four
  outcomes, the id that must never be dropped from a label. Handed a relation,
  every host app re-derives those and some get them wrong on a screen that looks
  fine. Now each is a method call.
- **`config.record_url`** — `->(type, id) { }` returning a path or nil, for the
  "also touched" list and the actor. nil by default, and deliberately never
  inferred from a class name: a wrong link on an audit screen is worse than none.
  Serves actors too, so there is no second lambda.
- **A third "Timeline" tab on the record screen**, rendered entirely from those
  value objects rather than the engine's own relations. A presenter nothing in
  the gem consumes drifts from what the auditor UI does.

Three decisions worth stating, since each looks like something to improve:

- **`Activity#headline` returns nil when nothing registered covered the write.** The
  library does not compose "Jane updated status and total" from column names.
  That would be this gem's phrasing rather than the app author's, would
  re-render differently after a gem upgrade, and would be indistinguishable on
  the page from a `summary` frozen at emit time — a recomputed sentence wearing
  the costume of immutable history. The host has i18n and its own model names;
  it gets `operations`, `record_type` and `changed_columns`, and `kind` says
  which it is holding.
- **The page-boundary rule.** An activity is hydrated with every change row of its
  unit of work, including rows past the end of the page, so a cursor never splits
  one save in half. The next page therefore starts on one of those older rows, so
  an activity whose newest row is newer than the page's own head was already shown
  in full and is dropped. Local, stateless, and can only ever drop a duplicate.
- **No authorization in the object.** It exposes everything and the host gates
  it. "Admins only" is a question about the host's roles that no lambda here
  would express better than its existing policy layer.

At this point the timeline was anchored on `audit_changes` alone, so no **write** to a record
can be missing from it whatever path it took. An event that named the record but
wrote no change row to it (`order.emailed`) does not appear, stays on the Actions
tab, and DESIGN §11.2b carries the union query that would close it — including why
a merged keyset needs `(max(occurred_at), request_id)` rather than
`(occurred_at, id)`: both tables have their own `bigserial`, so the naive cursor
has colliding tiebreakers.

The Timeline tab renders as a column of cards rather than a `table.grid`, and
that is not only cosmetic: the other two tabs answer "list every row matching
this filter", which is a grid, and this one answers "tell me what happened",
which is a narrative. The rail dot is the only thing carrying `kind` — filled for
a registered action, hollow for a change with no narrative — because a
recomputed sentence must never look like a summary frozen at emit time. The CSS
lives in the host app, as all of the auditor UI's does; the reference app's
stylesheet gained it.

Fixed while styling those cards, and it was a real hole rather than a cosmetic
one: the Timeline card rendered `metadata` with a bare `if activity.metadata.any?`,
so a **redacted** activity — whose metadata was emptied — rendered as nothing at
all. The card took its warm tint and said nothing about why. It now carries the
same three states as `shared/_event_payload`, with the notice deliberately
outside the `<details>`: a disclosure the reader has to click for is not a
disclosure. The note sits above the field changes, since it explains the
`[redacted ...]` values below it, and `audit_ui_spec` asserts it lands outside
every `<details>` on the page.

`audit_operation_badge(change)` now delegates to a new
`audit_operation_chip(operation)`, so a caller holding a bare operation code —
`Timeline::Activity#operations`, which is a value object's list of codes — gets the
same badge without a screen re-spelling the code-to-colour mapping.

Also: `Change.grouped_by_request` moved up to `AuditLog::Record`. Both tables
carry `request_id` and `occurred_at`, so a page of events hydrates its changes and
a page of changes hydrates its events through one bounded implementation.


### Narrative history for a single record  **[2026-08-28]**

`audit_events` has carried `subject_type` / `subject_id` and an index on
`(subject_type, subject_id, occurred_at DESC)` since the first migration, and
`AuditLog::Redaction` was the only thing in the library that read them. There was
no query object and no screen: "what was *done* to Order #4821, in words" had
storage, an index, and no answer. DESIGN §11.4's screens table had the same gap,
listing the record screen as `audit_changes` alone.

- **`AuditLog::RecordTimeline`** — the narrative half of Q2. `#events` is the
  actions that named this record as their `subject`: one index scan, ordered,
  unlimited, and the caller paginates it. `#correlated` is the actions that wrote
  to the record *without* naming it — a bulk update, a save whose subject was the
  parent, an action registered with no `subject:` lambda — found by matching
  `request_id` against the record's own change rows, since that is the only link
  between the two layers.
- **`/audit/records/:type/:id/history` gains an Actions tab**, alongside the
  existing change rows, which stay the landing tab and the compliance-grade
  answer. An unrecognised `?view=` falls back to them rather than to the capped
  list. The CSV export follows the open tab and names the tab in the filename, so
  two exports of one record cannot arrive under one name.
- **The correlated section is capped, and the cap is disclosed and escapable.**
  It reads a bounded number of the record's most recent change rows, prints how
  many it read, says so when there was more, and offers `?scan=` to widen it —
  the same treatment `RequestDrillDown` gives its date window. An unqualified
  "recent activity" heading over a silently truncated list is the failure this
  library exists to prevent.
- **The two populations render as two sections, never one merged list.** DESIGN
  §11.2a: merging presents "this action touched this record" as the same claim as
  "this action was about this record", and hides that only one half is capped.

Two things found while building it:

- **`where.not(subject_type: t, subject_id: i)` is NULL-unsafe and fails
  silently.** It compiles to `NOT (subject_type = t AND subject_id = i)`, which
  evaluates to NULL — and therefore excludes the row — whenever `subject_type IS
  NULL`. An action registered without a `subject:` lambda is exactly that row, and
  it is the single most important thing the correlated section is there to
  surface, so the natural spelling drops the whole population the feature exists
  for while the screen still renders. Now the row-wise
  `(subject_type, subject_id) IS DISTINCT FROM (?::text, ?::bigint)`.
- **`ActorActivity#changes_for` carried no date bound**, which made it the one
  drill-down in the library that scanned every partition — six today, 84 at a
  7-year horizon, on every page render of the actor screen. Both screens now go
  through **`AuditLog::Change.grouped_by_request`**, one implementation, bounded
  by the page's own events so the window infers nothing.

Also: `spec/preview.rb` grew screens for the new tabs (17 in total by the end of
this release), and its bulk price change now emits the `price.bulk_adjusted` it
was always registered for — it is the action with no `subject:`, so it is what
gives the product preview something to render in the correlated section.


### Extracted from the reference application

Everything below this heading predates the gem: `audit_log` began as
`lib/audit_log/` inside the `audit-log-demo` Rails application, and that history
is preserved here via `git subtree split`. The demo app remains the reference
implementation and now consumes this gem by path.

**Packaging**

- Conventional engine layout: `app/`, `config/` and `db/` at the gem root, and
  `Engine.find_root` deleted — it existed only to stop Rails' root-walk resolving
  to the host application while the library lived inside one.
- `lib/audit_log.rb` autoloads by feature name rather than absolute path, now
  that the gemspec puts `lib/` on the load path.
- Proprietary and internal: `LICENSE.txt`, `LicenseRef-Proprietary`, and
  `allowed_push_host` set to a non-host so `gem push` fails locally rather than
  publishing to rubygems.org.

**Two load-order bugs the extraction exposed.** Both were the library relying on
a host app's Gemfile order, which happened to be right inside the demo:

- `engine.rb` requires `rails` before `rails/engine`; `rails/engine` alone raises
  `NoMethodError` on ActiveSupport's `delegate_missing_to`.
- `configuration.rb` requires `numeric/time` and `integer/time` for its `24.hours`
  and `7.years` defaults, which ActiveRecord had always required first.

**Corrected version claims.** Both were unverified until CI tested them:

- `required_ruby_version` is **`>= 3.3.0`**, not 3.2. DESIGN §2.1 always said 3.3
  was the hard floor, entirely for `SecureRandom.uuid_v7` — which is
  `Context.new_request_id`, so on 3.2 every correlated write raises.
- `rails` is **`~> 8.0`**, not `>= 8.0`. `TransactionStamp` prepends the *private*
  `raw_execute`, so claiming untested majors was not credible. Raising the ceiling
  means re-verifying that prepend.

### Added

- `rails generate audit_log:install` — initializer, schema migration,
  `ControllerContext`/`JobContext` includes, the engine mount, and a three-line
  coverage spec. Idempotent, and it reports every step it could **not** do rather
  than reporting success. It refuses to change `schema_format` on an app that
  already has a `db/schema.rb`, and lands the `ControllerContext` include *after*
  the last `before_action` — ahead of authentication it would read an unresolved
  `current_user` and give every audit row a NULL actor.
- `rails generate audit_log:trigger TABLE [--model] [--exclude] [--replace]`.
  `--replace` generates detach-then-attach, the supported way to change a table's
  model or exclusion list.
- `AuditLog::Coverage` and `audit_log/rspec`, so the coverage forcing function
  ships with the gem instead of being copied per app. `rake audit_log:coverage`
  uses the same object, so the task and the spec cannot disagree. This also
  removed a genuine rule violation: the rake task named `ApplicationRecord`, a
  host application constant inside the library.
- `AuditLog::RecordLabel` and display-time association labels — a diff renders
  `product_id (not set) → Grommet 10mm (id: 51)`. Opt-in per model via
  `to_audit_label`; the id is never replaced. See DESIGN §11.8.
- GitHub Actions CI: the suite against `spec/dummy` on PostgreSQL 18, across Ruby
  3.3 (the gemspec floor) and 4.0.6, plus packaging gates asserting `gem build` is
  warning-free and `LICENSE.txt` travels inside the built gem.

### Renamed

- `config.stamped_databases` → **`config.correlated_databases`**. No deprecation
  alias: nothing outside this repo consumed the library yet, so a stale caller
  should fail loudly. The new name says what the setting gates — *who pays for the
  correlation round trip* — and stops implying it decides what is audited, which
  it does not: a database left out is still fully audited, its rows simply arrive
  with no actor and no `request_id`.

### Known gaps

- No `Rails 8.0` CI leg, so `AuditLog.notify`'s documented fallback for the
  absence of `Rails.event` is untested at the floor the gemspec claims.
- Untagged. A host app depending on `git:` tracks `main` and cannot pin.
