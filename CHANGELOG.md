# Changelog

## Unreleased

### The README reads top-down for two audiences  **[2026-08-29]**

It had grown by accretion, so the order was the order things were built rather
than the order anybody reads them. Deep reasoning sat between steps somebody
needed to follow.

Reordered so the first two thirds are for a developer installing and using the
gem — summary, what is optional, getting started, installing, emitting events,
reading a record's history, building one on your own pages, association labels,
rake tasks — with nothing between those steps that is not needed to take them.

Then two new sections:

- **Advanced** — the reasoning behind the parts most likely to surprise you.
  "Attaching to a table that already exists" and "Re-attaching, and changing a
  table's exclusions" moved here from the middle of the install flow: the
  *instruction* is one generator flag, while the explanation (why attaching is
  deliberately not idempotent, why `CREATE OR REPLACE TRIGGER` is refused) is
  three screens somebody only needs when it bites. "Why objects and not
  relations" moved here for the same reason — rationale, not instruction.
- **Working on this library** — Files, what reloads and what does not, before you
  change anything, and deliberately-not-implemented, all of which only matter if
  you are changing the gem rather than using it.

"Emitting events from a controller action" was promoted out of "Installing" to a
section of its own, and now says outright that it is **optional** — skipping it
costs readability, never completeness, which was true all along and stated
nowhere.


### Freezing is automatic now  **[2026-08-29]**

DESIGN §8 gains **"Why freezing matters at all"**, because every mention of
freezing in this repo assumed the reader knew — 32-bit transaction ids wrap, so
old rows must eventually be marked frozen or an anti-wraparound vacuum forces a
full scan of the largest table in the database at a moment Postgres chooses.
Append-only tables are precisely the shape ordinary vacuuming ignores until then.
Freezing is therefore not optional; only its *timing* is, which is the entire
feature. Stated with the hedges it deserves: PG 13's insert thresholds and PG
18's eager freezing both soften the problem without removing it.


`audit_log:partitions` — the daily task — now freezes each partition once its
month closes, so nobody has to decide when to run `freeze`.

**A marker is what made that possible.** `freeze_closed!` re-froze *every* closed
partition on *every* call: unbounded work growing with the retention horizon,
plus an `ANALYZE` re-sampling statistics that cannot have changed on an immutable
partition. That is precisely why it needed a human to pick a moment. Each frozen
partition is now marked with a table comment, so the daily run does only what is
newly closed — nothing on most days, one partition per table on the first run of
a month.

Two orderings in it are load-bearing:

- **Provision first, freeze second.** Creation is the half whose failure is a
  write-path outage, so it commits before a `VACUUM` that might turn out slow.
- **VACUUM first, mark second.** The reverse would skip a partition forever if
  the VACUUM failed after the comment committed; this way a failure just means it
  is retried tomorrow.

**Redaction clears the markers.** It issues `UPDATE` against the parent table, so
it reaches every attached partition including frozen ones and dirties pages
there. Left marked, such a partition would never be frozen again and the
anti-wraparound vacuum freezing exists to pre-empt would arrive anyway — on a
table everybody believed was handled. It clears all of them, because it filters
on record type and id and cannot know which months it touched; the daily task
re-freezes over the following runs.

**A drain deliberately does not**, and that absence is documented because it
looks like an oversight. The design started with drain-clears-markers, and the
spec written to prove it failed with `PG::CheckViolation`: Postgres refuses an
insert into the default partition whose range another partition already claims.
Rows reach the default only when *nothing* covers their month, so a drain's
targets are always partitions it created moments earlier — new, and therefore
unfrozen. The guard was removed rather than shipped with a comment claiming it
was load-bearing.

`audit_log:partitions:freeze` stays as a manual catch-up, with `FORCE=1` to redo
partitions already marked.

Freezing also had **no specs at all** before it started running daily, which is
exactly when it needed them. `VACUUM` cannot run inside a transaction and every
example runs in one, so the VACUUM statement is swallowed and the assertions
cover selection and marking — which is where the logic lives.

345 examples, 0 failures.


### The partition lifecycle: a namespace, a marker, and no way to drop by accident  **[2026-08-29]**

Four changes, one theme — retention should be incapable of destroying anything,
and everything about the lifecycle should be nameable.

**`audit_log:partitions:` namespace.** The seven lifecycle tasks nest under it,
and `audit_log:partitions` **keeps its bare name** — Rake stores tasks by full
name string, so a task and a namespace may share one (verified in a real app).
The daily cron line, whose failure is a write-path outage, never had to change.
The namespace also disambiguates the rest for free: `partitions:drain_default`
says which "default" it means, where a bare `drain_default` does not.

**`config.retention_action` is removed. Retention only detaches.** It accepted
`:detach` or `:drop`, defaulting to the reversible one — which meant a single
line in an initializer could turn a *scheduled* task into one that destroys audit
data. A safe default is weaker than an absent option: a default can be flipped
and nothing reports it. Retention decides what is past the horizon; disposal is a
separate decision somebody types.

**Retiring now stamps a `RETIRED_MARKER` table comment**, in the same transaction
as the detach and the rename, carrying the partition's exclusive upper bound. It
does two jobs a name cannot:

- *Provenance.* `audit_changes_retired_2019_01` is a name anybody can create, and
  a manual copy taken before a risky migration is the obvious way it happens —
  dropping on a name match would destroy it while the operator believed they had
  made a backup. The same rule `ROLLUP_MARKER` already established for rollup
  staging tables, applied where it was missing. Unmarked lookalikes are now
  **reported**, never silently skipped.
- *The date range.* `DETACH` clears `relpartbound`, so retiring destroys the
  authoritative record of what period a partition covers — and the name is the
  very artifact `misaligned_bounds` exists because it lies. `BEFORE=` compares
  the recorded upper bound, so `BEFORE=2025-06-01` correctly leaves a `2025`
  yearly partition alone. An unreadable marker is skipped rather than guessed at.

**Three disposal tasks instead of one**, so the choice belongs to the adopter:

| | |
|---|---|
| `export_retired` | export every retired partition, verified |
| `drop_retired` | drop without checking for an export ⚠ |
| `export_and_drop_retired` | export → verify → drop only what verified ← recommended |

`export_retired` now exports **everything, every run**. It used to skip a
partition when two files existed in `DIR`, which is evidence of nothing: the file
may be truncated, corrupt, a stale export of an earlier state, or on a container
filesystem that ceased to exist. Skipping on that basis means the one case where
a re-export matters — the archive went bad — is precisely the case it skips,
while reporting success. Nor can this library know whether a file reached durable
storage, so it stops pretending to track that.

Which made **atomic writes** necessary rather than nice: `export!` opened the
destination with `"wb"`, truncating at byte zero, so a re-export interrupted
mid-stream would have destroyed a good archive to produce a partial one. It now
writes to a temp file, fsyncs, verifies, and renames into place — the previous
export survives until the new one is complete *and* verified. (`gz.finish`, not
`gz.close`: close takes the underlying file with it and the fsync then fails.)

**Export also verifies now**, rather than only at drop time. Until this,
verification happened solely as a side effect of dropping, so an operator who
exported monthly and never dropped had never once checked that their archives
were readable — and would find out the first time they needed one.

DESIGN §8 gains **The partition lifecycle**: every state, what it means, and —
the part not derivable from the code — *who can still read the data in it*. Two
consequences it states outright: redaction stops at the retirement boundary,
because `Redaction` updates the parent and a detached partition is no longer part
of it; and retired is reversible while dropped is not.

340 examples, 0 failures.


### "Only partitions belongs in a cron" was too strong  **[2026-08-29]**

DESIGN §8, CLAUDE.md and the new task reference all said only
`audit_log:partitions` belonged in a cron. The reason behind it is real — three
maintenance tasks take `ACCESS EXCLUSIVE` and block every audited write while
they run — but the conclusion overshot, and contradicted DESIGN §16's own
principle that **a forcing function which runs when somebody remembers is not
one**. An app with a seven-year horizon whose retention waits on a human
remembering, monthly, for seven years, does not have retention.

The rule is cadence and conditions, not prohibition:

- **`partitions`** — daily, mandatory. Failure is a write-path outage.
- **`retention`, `rollup`, `freeze`** — schedule them, monthly or quarterly, in a
  low-traffic window. Lock contention and lock timeouts **raise**, so a bad
  moment is a non-zero exit and a retry next cycle rather than a silent skip —
  which is only true if the scheduler surfaces failures. Both `retire!` and
  `rollup!` commit *per partition*, so a mid-run failure leaves earlier ones done
  and the output matters more than the exit status.
- **`drain_default`** — the one real prohibition. Needing it means a row reached
  the default partition, which means rotation was not running. Scheduling the
  repair hides the fault that caused it.
- **`retention_action = :drop`** — automating destruction. The `:detach` default
  is reversible with one `ATTACH`; a scheduled `:drop` should be a decision
  somebody made deliberately, ideally behind `export` and `drop_exported`, which
  verifies before deleting.

DESIGN §8 carries a dated amendment rather than a silent edit, since the original
claim is cited from CLAUDE.md and the README.


### PostgreSQL 16 is the floor, and CI now proves it  **[2026-08-29]**

The README called PostgreSQL 18 a hard requirement. DESIGN §20 has said the
opposite since it was written — *"targets PG 16 and requires nothing newer"* —
and a code audit agrees: the newest thing the library uses anywhere is
`gen_random_uuid()` (PG 13) in the benchmark task, and the partitioning is all
PG 11-era. `uuidv7()` is PG 18 and belongs to the reference app's **seeds**;
`spec/dummy` has none.

Verified rather than reasoned about: the full suite (332 examples), the schema
install, and `audit_log:coverage` / `partitions` / `reconcile` all pass against
**PostgreSQL 16.13**.

CI gains a Postgres dimension — 16 and 18 — for the same reason the Ruby 3.3 leg
exists. That leg was added claiming 3.2, matching the gemspec, and failed
immediately on `SecureRandom.uuid_v7`: a floor nothing runs against is a guess,
and this one had been wrong in the docs for a while without anybody noticing. If
the 16 leg ever fails, fix the code or raise the floor in DESIGN §20, the README
and CLAUDE.md together.

The CI comment justifying `postgres:18` was wrong too — it cited "uuidv7() in
seeds", which is not this repo's code.


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
- GitHub Actions CI: the suite against `spec/dummy` on PostgreSQL 16 and 18, across Ruby
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
