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
| `README.md` | someone installing the gem | install, use, the auditor UI, and the optional generated views |
| **`CLAUDE.md`** (this file) | you | terse rules, and what not to "fix" |
| `DESIGN.md` | someone changing the library | the reasoning, in full |
| `CHANGELOG.md` | everyone | what changed between released versions. Deliberately thin — `DESIGN.md` carries the reasoning, git carries the detail |
| `llms.txt` | an agent in a HOST APP using the gem | a summary and a routing table into README/DESIGN. **Packaged** (`spec.files`); `CLAUDE.md` deliberately is not. DESIGN §24 |

The list of deliberate decisions below is deliberately terse and deliberately
duplicated from `DESIGN.md` — it exists so an agent that will not read that
whole document still does not "fix" a decision. **When the two disagree,
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

## What belongs in which document

**`DESIGN.md` §22 is the authority.** The terse copy:

`README.md` is for somebody **using** the gem. `DESIGN.md` is for somebody
**changing** it. The README also has an internal split:

- **Early** (Summary → the feature guides) — a developer works down it and ends
  up correctly installed and configured, with at least introductory knowledge of
  every feature. Examples assume the ordinary case: **one database**, no
  `connects_to`, no savepoints.
- **Later** (Configuration, Generator options, Rake tasks, Advanced) — reference
  tables, and topics reached when a reader has a reason rather than on the way in.

**The test for any paragraph: does it change what the reader does?** If yes it
stays in the README; if it merely explains why the decision was made, it moves to
`DESIGN.md`. Backstory, measurements, rejected alternatives, bug archaeology, the
version history of an API, and "what this used to do" are all DESIGN material,
however interesting — and they are what this README keeps accreting.

**One exception, load-bearing:** a "why" that prevents a MISUSE stays. *"The
default is unbounded on purpose — a bound nobody asked for is invisible
truncation"* is rationale, and it is the only thing stopping a reader quietly
truncating a compliance screen. The test is not "is this rationale" but "does the
reader behave differently without it".

**"Too deep for the intro" and "belongs in DESIGN" are different judgements.** An
option a user must eventually set — `on:`, `correlated_connections` — moves LATER
IN THE README, not out of it. Only the reasoning behind it goes to DESIGN.

**Moving depth out leaves a `§n` pointer, and `readme_spec` asserts every one of
them resolves to a real DESIGN heading.** A pointer into nothing is worse than the
paragraph it replaced: the reader has been told there is more and cannot find it.
DESIGN gets renumbered; that spec is what makes it safe. Do not delete a DESIGN
section without checking what points at it — the spec will tell you.

## The one rule that matters most

**This gem must never reference an application constant.** No `User`, no
`Order`, no `ApplicationRecord`, no Devise, no app I18n key. Every coupling point
is a lambda or string on `AuditLog.config`, configured in
`config/initializers/audit_log.rb`. If you need the library to know something
about the host app, add a config attribute — do not reach for the constant.

It assumes only that the host app exposes `current_user` in controller scope and
that the actor produces a label (`to_audit_label`, else `to_label`, else a
name/email pair, else `Class (id: n)`). Both are resolved through config.

`README.md` is the extraction guide and the design-decision record.
Update it when you change behaviour.

## Environment

| | |
|---|---|
| Ruby | **>= 3.3** — the floor is `SecureRandom.uuid_v7` (DESIGN §2.1), not a preference. 3.3.0 exactly also cannot run Rails 8.1, for a reason of Rails' own. Developed on 4.0.6. |
| Rails | **`~> 8.0`** — floor 8.0 (DESIGN §2.2), and a real ceiling below 9.0 because `TransactionStamp` prepends the *private* `raw_execute`. Developed on 8.1.3.1. |
| PostgreSQL | **>= 16.** Developed on 18.6, port 5438 — not the workspace default 5437. CI runs 16 and 18; DESIGN §20 is the authority and says the design "targets PG 16 and requires nothing newer". Verified: the whole suite passes on 16.13. |
| Tests | RSpec against `spec/dummy` (508 examples), on every push via GitHub Actions — six legs: Ruby 3.3/4.0.6 × Rails 8.0/latest × PG 16/18 |
| Runtime deps | `rails`, `csv` (export). **`pg` and `pagy` deliberately are not** — the host app picks its own `pg` build, and its own pagination gem. `AuditLog::Pagination` is this library's own keyset pager precisely so a `pagy` constraint does not propagate into the host. |

```bash
bundle install
cd spec/dummy && RAILS_ENV=test bundle exec bin/rails db:create db:migrate
bundle exec rspec                       # from the gem root
RAILS_VERSION="~> 8.0.0" bundle install && bundle exec rspec   # the Rails floor, as CI runs it
bundle exec rspec spec/preview.rb       # renders all 19 engine screens to spec/dummy/public/
```

`spec/dummy/db/structure.sql` is **git-ignored on purpose**. For a disposable app
it does more harm than good: `db:migrate` loads it in preference to re-running
the migrations, so editing a migration silently does nothing. Delete it and
re-migrate if a schema change appears not to apply.

## Things that look like bugs but are deliberate

Do not "fix" these without reading the linked reasoning first.

- **`audit_log:install` refuses to set `schema_format` when `db/schema.rb`
  exists, and that refusal is a feature.** (DESIGN §21.2.) `:sql` is required *before* the first
  migration; switching an established app means re-dumping its whole schema and
  every developer rebuilding their database. A generator must not start that
  quietly — it reports the three steps and stops.
- **The `ControllerContext` include is injected after the LAST `before_action`,
  not at the top of the class.** (DESIGN §21.2.) `inject_into_class` puts it at the top, which
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
- **Nothing here is qualified with `public`; everything operates on
  `current_schema()`.** The trigger function is installed BESIDE the tables it
  writes to and names them in full (`{{schema}}` is substituted by
  `AuditLog::Schema.install_function!`), and `attach_audit_trigger` references it
  UNQUALIFIED so `CREATE TRIGGER` binds permanently to the copy installed by the
  same migration run. This is not multitenancy support — it is the removal of an
  assumption, and it costs a single-schema app nothing because `current_schema()`
  is `public`. Both directions of the old assumption failed silently: a function
  pinned to `public` filed EVERY schema's rows in one table while the writes
  succeeded, and `Partitions.exists?` asking `to_regclass('public.' || name)`
  found public's partition, reported the work done, and provisioned nothing —
  leaving a parent with no partitions that died on its first write. The mirror
  image is just as bad: `attached?`, the inventory queries and both `Coverage`
  queries filtered on `relname` ALONE, so one schema's trigger vouched for
  another schema's table and the coverage forcing function passed while a table
  went unaudited. Do not "simplify" any of this back to a literal, and do not
  reach for `TG_TABLE_SCHEMA` + a dynamic `EXECUTE` — it is correct but re-plans
  on every audited write, taxing every app to serve the rare one. DESIGN §14.
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
- **`AuditLog.audited` builds its payload in TWO slots, and the split is the
  design.** Keyword arguments are evaluated before the block, which is right for
  IDENTITY AND INPUTS (ids, references, a `reason` off params, the actor label)
  and silently wrong for OUTCOMES — `spec/dummy` `Order#submit!` recalculates
  `total_cents` from the line items it reprices, and `order.shipped`'s
  `tracking_number` belongs to a record the block has not created yet. An outcome
  in the keyword slot files pre-write state under a sentence describing the write
  and renders without complaint. Nothing can prove a value is an input, so the
  one buildable guard is `Payload`'s: **a key set in both slots raises**, with a
  message naming the fix rather than reporting the collision — that is the only
  moment the rule reaches somebody breaking it. An earlier draft made the payload
  the block's RETURN VALUE, on the theory that it made the mistake impossible; it
  does not (a hash built at the top of the block and returned at the bottom is
  just as stale, with no guard), and it cost the block's return value and made
  the last expression load-bearing. Do not go back to it, and do not add a
  `payload:` lambda beside the two slots. The emit is the last statement INSIDE
  the transaction, never `after_commit`: a raise skipping it is what "only if the
  writes succeeded" means, and it keeps the other direction of R3 — a failed
  event write still rolls the changes back. `on:` opens the transaction and
  defaults to `ActiveRecord::Base`, which wraps NONE of the writes for a model on
  a secondary connection via `connects_to`; the README shows `on: self`. DESIGN §7.
- **`Registry.register requires:` raises on a missing payload key, and its three
  softenings are each deliberate.** It is the third point that makes the call
  site's keys and the entry's `p[...]` reads agree, so a typo on EITHER side
  fails against it — worth having because summaries are frozen at emit time, so
  a holed sentence can never be repaired. The check lives in
  `EventSubscriber#emit`, the ONE point `notify`, `audited` and a bare
  `Rails.event.notify` all cross; putting it in `audited` would make the guard a
  reason to prefer one call site over another. It therefore runs inside the
  caller's transaction, so a violation rolls the change back — same position as
  `raise_on_error`. The softenings: (1) **opt-in per entry** — no `requires:`
  means unchecked, which is what keeps a rare branch from being a production
  landmine, and deleting the line is the escape valve. There is deliberately NO
  config flag to soften it globally, for the reason `retention_action` is gone.
  (2) **extras pass and are still stored** — payloads grow, and a call-site typo
  is already caught by the missing half. (3) **`key?`, not the value** —
  `metadata` is stored `.compact`ed, so a deliberate `reason: nil` and a
  forgotten `reason:` are the same row, and the declaration is the only place
  that distinction survives. A declaration lists what the entry cannot RENDER
  without, not every key it reads: `audit.redaction` reads `columns` and requires
  it not, because `Array(p[:columns]).presence || "all recorded values"` has
  already decided it is optional. DESIGN §7.
- **`spec/dummy` declares `requires:` on fourteen entries and leaves
  `order.deleted` undeclared ON PURPOSE.** An app where every entry declares one
  leaves the library's "unchecked without it" claim untested, and `order.deleted`
  is consequently the only action that can be emitted with an empty payload —
  which is the state `shared/_event_payload` renders as nothing, and
  `audit_ui_spec` needs somewhere to assert it. Do not "finish the job" by
  declaring it. `payload_contract_spec` pins that exactly one entry is undeclared.
- **`AuditLog.audited` JOINS a caller's open transaction, yields that transaction
  as a second block argument, and RAISES on a Rollback it could not honour.**
  There is no way to hand Rails a transaction handle — `ActiveRecord::Transaction`
  cannot be passed back into `transaction` to re-enter — so joining IS the
  handover, and yielding the object is how a caller reaches `after_commit`
  without opening a transaction purely to get one. When joined it is the
  CALLER's transaction, so callbacks fire on their outermost commit;
  `audited_spec` pins that by object identity. A joined transaction swallows
  `ActiveRecord::Rollback`, and the sugar hides the nesting, so without the guard
  the writes commit, no event is emitted, and `audited` returns nil as though it
  had rolled back — measured, not reasoned about: the order committed as
  "submitted" with zero `audit_events` rows. The guard reads `tx.open?` AFTER the
  transaction block returns, which is public API needing no connection handle (AR
  instances expose none): owned — real or savepoint — is closed by then, joined
  is still open. Do NOT re-spell it as `connection.open_transactions` or
  `transaction_open?`. `current_transaction` compared by identity is equally
  correct and was evaluated — it is a CLASS method, and `on:` is idiomatically an
  instance, so it costs a normalisation for no gain; it IS the right idiom on the
  CALLER's side, where `NullTransaction#after_commit` runs immediately when no
  transaction is open. And do NOT default to `requires_new: true` to dodge the
  whole thing — that would take a savepoint on every nested call and change
  atomicity for everyone. `transaction:` passes options through; it and `on:` are
  the only keywords reserved from the payload. **`transaction.before_commit` does
  NOT exist** in 8.0.5.1 or 8.1.3.1 even though Rails' own doc block for this API
  shows it — verified by running it; it raises `NoMethodError`. Do not add it to
  an example here. DESIGN §7.
- **`AuditLog::Payload` WRAPS a Hash and must not subclass one, and `merge`
  without the bang is a tombstone that raises.** Subclassing publishes `delete`,
  `clear`, `replace` and `reject!` as things a block may do to an audit payload —
  the same argument that keeps `Timeline::Activity` from being an
  `ActiveRecord::Base`. And Ruby's `merge` returns a new hash and leaves the
  receiver alone, so on a collector it is a silent under-report: keys computed,
  discarded, event emitted without them, summary rendering a gap, nothing raised.
  `[]=` has no such twin, which is why it needs no tombstone. Keys are normalised
  to symbols because `EventSubscriber#emit` symbolizes at write time — without
  it, `audit["order_id"] = x` against an eager `order_id:` is two keys that
  collapse there and silently take whichever landed last, walking past the guard
  above. Ruby 3 admits non-Symbol keys in KEYWORD arguments too, so `merge!`
  normalises its kwargs as well as its positional hash; a spec caught that hole.
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
  **The SPELLING is `(id: 51)`, and BOTH renderers owe it** — the engine's
  `audit_value` and the generated `ActivityHelper#activity_value`. The template
  had drifted to a bare `(51)`, which reads as part of the label (a quantity, a
  code, a price) on the one screen whose claim is that the annotation never
  displaces the recorded fact, and left the two screens disagreeing about which
  parenthesis is the id. Pinned on both sides now:
  `association_labels_spec` on the engine's, `activity_generator_spec` on the
  template's.
- **A recorded identity is spelled `Order (id: 6064)`, never `Order #6064`, and
  `AuditLog::Identity` is the ONE place that decides it.** The `#` went because
  host apps overwhelmingly use it for an identifier of their own — an order
  number, an invoice number, a ticket reference — so on an audit screen the
  reader cannot tell which number the log recorded, next to a live-resolved label
  whose whole job is to not be mistaken for the recorded fact. What fixes it is
  the NAME inside the annotation, not the bracket: `#` is a bare sigil that says
  nothing about what it prefixes, while a host label containing `(West)` can
  never be confused with `(id: 51)`. **Parens rather than brackets was checked,
  not preferred** — this UI already spends both. Parens are what the screens use
  for an annotation the audit UI added rather than data it recorded
  (`(not found)`, `(label unavailable)`, `(unrecorded)`); `[` is
  `Redaction::MARKER_PREFIX`, so `[redacted 2026-09-01 per …]` renders in the
  same column and `[id: 51]` would put a routine annotation in the erasure
  delimiter. Three forms, and the diff cell is the general case:
  `annotation(id)` where the column already named the type, `for(type, id)`
  standalone, `labelled(label, type, id)` → `Grommet 10mm (Product id: 51)`.
  **Two callers STORE their result** — `Configuration#default_actor_label`
  snapshots into `actor_label` and a registry `summary:` is frozen at emit time —
  so old rows keep the old spelling and the actor column is mixed from here on.
  That is what a snapshot means; do NOT add a migration that rewrites them. There
  is deliberately no `config.identity_format`: a host could set it back to `#`.
  It exists as a module because the same interpolation was hand-spelled in seven
  places and nothing made them agree — the Changes tab and the Timeline tab of
  one record screen drifted apart the first time a single one was edited, which
  is the `ActorLabel.display` lesson again. `identity_spec` greps `app/` and
  `lib/` for a hand-rolled copy. DESIGN §11.8.
- **`AuditLog::RecordLabel`'s chain ends in `nil`, not in `"Product (id: 51)"`** — the
  other place it deliberately differs from `ActorLabel`, whose chain must end in
  something because its column would otherwise be blank. Here the id renders
  unconditionally, so a model with no hook must produce no label and leave the cell
  byte-identical to before the feature existed. That nil ending *is* the opt-in.
  The chain is `to_audit_label` → `to_label` → a deliberately overridden `to_s`
  — **the same head `Configuration#default_actor_label` uses**, and only the tail
  differs (that default ends in `Class (id: n)` because the actor column would
  otherwise be blank),
  and **there is deliberately no `name`/`title` column sniffing** — guessing which
  column reads as a label is how a screen confidently captions an id with the wrong
  string. Adding a sniffing fallback, or a `"Type (id: n)"` terminal, both look like
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
- **`AuditLog::Pagination` depends on NOTHING, and that is the point of it being
  hand-rolled.** It was `Pagy::Keyset` until 0.2.0. Bundler resolves one `pagy`
  per app; keyset paging exists in Pagy from 9.0 and the
  `jsonify_keyset_attributes:` hook `FULL_PRECISION` needs only from 9.3, and
  Pagy 43 removed that hook again — so an honest dependency was `~> 9.3`, two
  releases, propagated into every adopter's own pagination. Nothing here ever
  used Pagy's frontend. Do not reintroduce the dependency to save ~90 lines.
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
  labels loaded. Keyset paging needs a RELATION to mint a cursor, so what comes out of
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
  that same name, or ActiveRecord raises `PG::UndefinedTable` just loading the class — and `occurred_at` must be a typed timestamptz or the
  cursor cannot render at microsecond precision, which is the
  `FULL_PRECISION` bug all over again. (2) `attribute :key, :string` declares the
  synthetic column. (3) Callers must order with `arel_table[:key]`, never
  `order(key: :desc)` — a non-column name renders as an `Arel::Nodes::SqlLiteral`
  and `Pagination::Page#extract_keyset` calls `.name` on it. `timeline_spec` pins all
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
  (Product id: 51)`, never `Grommet 10mm`. The label is resolved live from current
  state; the id is what the log recorded (DESIGN §11.8). A host building a pretty
  timeline will want to drop it, which is exactly why the pretty method is the
  one that keeps it.
- **`TouchedRecord#field_changes` exists because the ENGINE could link and a host
  cannot.** `columns` says a line item's `quantity` changed; this says it went
  from 10 to 20. The engine can send the reader to `record_history_path` for the
  rest, but `config.record_url` points at the host's *business* page — current
  state, not history — and a line item usually has no page at all, so on a
  host-rendered timeline the values are nowhere else. It costs no query: the
  unit's whole change set is already hydrated and already warmed, and
  `Timeline#touched` was discarding the rows after reading `operations` and
  `changed_columns` off them. Lazy and memoised, so a screen rendering only the
  count pays nothing; `timeline_spec` pins the count at zero. It is built through
  **`FieldChange.from_changes`, the ONE construction path**, shared with
  `Activity#field_changes` — the `side:` argument and the MISSING/FAILED collapse
  are what a second hand-rolled copy gets subtly wrong. Rendered COLLAPSED inside
  a disclosure that is itself collapsed, because forty line items × five values
  expanded by default buries the card's own answer; `audit_ui_spec` asserts the
  nested `<details>` is closed, not merely present. And that spec's
  "redaction note is outside every `<details>`" assertion is now PARSED rather
  than regexed — a non-greedy `<details>.*?</details>` scan stops at the inner
  close tag and quietly stops checking the rest of the outer one. DESIGN §11.2b.
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
- **`config.correlated_connections` takes CONNECTION names, never database
  names, and the engine refuses to boot on a value that matches nothing.** It is
  compared against `connection.pool.db_config.name`, so `%w[primary]` (the
  default) is right for nearly every app — **including one whose `database.yml`
  has no `primary:` key at all**, because Rails names a flat single-database
  config `primary`. A database name here matches no connection and the failure is
  SILENT: every trigger still fires and every row is still written, all with a
  NULL actor and NULL request_id. It was called `correlated_databases` until
  2026-08-30, which invited exactly that, and a real app was configured with its
  database name. `Configuration#verify_correlated_connections!` raises when
  nothing matches and only warns on a partial miss — `%w[primary replica]` is
  legitimate where test has no replica. Do not soften the raise into a warning,
  and do not "helpfully" fall back to the first available connection: a guess
  here reintroduces the silence.
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
- **A timestamp on a screen is formatted HERE, never through `l(time, format:
  :short)`.** That read the HOST's `time.formats.short`, so an app I18n key
  decided the format of every timestamp in the auditor UI — the forbidden
  coupling, reached through a helper. A real install had set it to a time-only
  format and got audit screens with NO DATE; Rails' own default omits the YEAR on
  a log kept seven years. Three properties are load-bearing now: **the zone is
  always named** (two readers seeing different unlabelled numbers is worse than
  everyone seeing UTC); **the reader's zone is progressive enhancement, in that
  direction** — the server renders UTC and a ~25-line inline script re-renders
  through `Intl.DateTimeFormat`, so no JS, a blocked script or a hostile CSP
  leaves a complete timestamp rather than a blank column, and rendering an empty
  element for the script to fill is the way to break it; and **`datetime` and
  `title` keep the recorded instant at microsecond precision**, so a local
  rendering never becomes the only account of when something happened. No date
  library — `Intl` is platform, and a dependency here lands in every adopter.
  `config.display_time_zone` is `:viewer` or `:utc` and REFUSES TO BOOT on
  anything else (`correlated_connections`' argument: `:local` would fall through
  to UTC for everyone, silently). There is deliberately no `:app` value — the
  host's `Time.zone` is neither the reader's zone nor the recorded one. DESIGN §4.
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
- **Freezing exists because transaction ids wrap.** Postgres compares 32-bit
  xids for visibility, so old rows must eventually be marked frozen or an
  anti-wraparound vacuum forces a full scan of the largest table in the database
  at a moment it chooses. Append-only tables are the shape that gets ignored by
  ordinary vacuuming until then. So freezing is not optional — only its TIMING
  is, and that is the whole feature. DESIGN §8, "Why freezing matters at all".
- **Freezing runs in the DAILY task, bounded by `FROZEN_MARKER`, and the marker
  is what makes that possible.** `freeze_closed!` used to re-freeze every closed
  partition on every call — unbounded work growing with the retention horizon,
  plus an `ANALYZE` re-sampling statistics that cannot have changed on an
  immutable partition. That is what forced an operator to choose a moment.
  Marked, it does only what is newly closed: nothing most days, one partition per
  table on the first of a month. VACUUM first and mark second, never the reverse
  — marking first would skip a partition forever if the VACUUM then failed. And
  provisioning commits BEFORE the freeze in the daily task, so a slow VACUUM
  cannot delay the half whose failure is a write-path outage.
- **`AuditLog::Redaction` clears every frozen marker, and a drain deliberately
  does not.** Redaction UPDATEs the PARENT, so it reaches every attached
  partition including frozen ones and dirties pages there; left marked, the
  anti-wraparound vacuum freezing exists to pre-empt arrives anyway, on a table
  everybody believed was handled. It clears all of them because it filters on
  record_type/record_id and cannot know which months it touched. A DRAIN needs
  none of this, and the reason is worth keeping because its absence looks like a
  bug: Postgres refuses an insert into the default partition whose range another
  partition claims, so a drain's targets are always partitions it created moments
  earlier — new, therefore unfrozen. Verified, not assumed; a spec asserting the
  drain path failed with `PG::CheckViolation` proving the row cannot get there.
- **The partition tasks live under `audit_log:partitions:`, and the daily task
  keeps the bare name.** Rake stores tasks by full name string, so a task and a
  namespace can share one — verified in a real app, not assumed. That is the
  point: the daily cron line is the one whose failure is a write-path outage, and
  it never had to change. The namespace also disambiguates the tier-3 names for
  free — `partitions:drain_default` says which "default" it means.
- **`audit_log:partitions` is the only task that belongs in the DAILY cron — but
  that is not the same as "the only task you may schedule", which is what this
  said until 2026-08-29.** `retention` and `rollup` are exactly what an app with a
  compliance horizon should schedule monthly: retention that waits on somebody
  remembering, for seven years, is an intention rather than a policy, which is
  DESIGN §16's own argument about forcing functions. The real rules are cadence
  and conditions. Both take `ACCESS EXCLUSIVE` on an audit table and block every
  audited write while they run, so they want a low-traffic window;
  they run under `config.maintenance_lock_timeout` (5s) and RAISE on contention
  rather than queueing, so a bad moment is a non-zero exit and a retry next cycle
  — but only if the scheduler surfaces it. `retire!` and `rollup!` commit per
  partition, so a mid-run failure leaves earlier ones done and the output matters
  more than the exit status. **`freeze` is not a third here** — the daily task
  absorbed it, and `VACUUM (FREEZE, ANALYZE)` takes `SHARE UPDATE EXCLUSIVE` and
  no advisory lock, so it never blocked writes to begin with.
  **`drain_default` is the one that genuinely must not be scheduled**: needing it
  means a row reached the default partition, which means rotation was not
  running, and scheduling the repair hides the fault.
  DESIGN §8 carries the amendment.
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
- **Retention CANNOT drop, and `retention_action` is gone.** It took `:detach` or
  `:drop`, defaulting to the reversible one — which meant one line in an
  initializer could turn a SCHEDULED task into one that destroys audit data. A
  safe default is weaker than an absent option, because a default can be flipped
  and nothing reports it. Retention decides what is past the horizon; disposal is
  a separate decision somebody types. Do not reintroduce the option.
- **Retiring stamps `RETIRED_MARKER` in the same transaction as the detach and
  rename, and every export/drop works only from marked partitions.** Two jobs a
  name cannot do. PROVENANCE: `audit_changes_retired_2019_01` is a name anybody
  can create — a manual copy before a risky migration is the obvious way — and
  dropping on a name match would destroy it while the operator believed they had
  a backup. Same rule `ROLLUP_MARKER` already established, applied where it was
  missing. THE DATE RANGE: `DETACH` clears `relpartbound`, so retiring destroys
  the authoritative record of the period, and the name is the very artifact
  `misaligned_bounds` exists because it lies. `BEFORE=` keys on the UPPER bound,
  and a partition whose marker will not parse is skipped rather than guessed at.
  Unmarked lookalikes are REPORTED, never silently skipped.
- **`export_retired` exports everything, every run, and that is not waste.** The
  old version skipped a partition when two files existed in `DIR`, which is
  evidence of nothing: the file may be truncated, corrupt, a stale export of an
  earlier state, or on a container filesystem that no longer exists. Skipping on
  that basis means the one case where a re-export matters — the archive went bad
  — is the case it skips, while reporting success. It writes through a temp file
  and renames, which is what makes re-exporting safe rather than a trade: opening
  the destination directly truncates a good archive at byte zero. `gz.finish`,
  never `gz.close`, or the fsync below it hits a closed stream.
- **`drop_retired` does not check for an export, on purpose.** A file in a
  directory is not proof of preservation, so requiring one buys less safety than
  it looks like — and forcing every adopter to produce CSV archives is not this
  library's decision. `export_and_drop_retired` is the verified path and the one
  to recommend; both are marker-gated.
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

### Dimensions (DESIGN §23)

- **A dimension value is a SCALAR read from `NEW` (`OLD` on delete), never an
  `OLD ∪ NEW` array, and the cost of that is real and accepted.** A row is filed
  under the value it held AFTER the change, so departures are not captured: an
  invoice moving from department 5 to 9 shows in 5's feed up to but not including
  the move. The array encoding was designed in full and works — jsonb containment
  has array semantics — and it breaks the guessable query:
  `dimensions @> '{"department_id":"5"}'` returns NOTHING against an array-valued
  column, silently, in a feature whose entire premise is convenient ad-hoc
  querying by hosts who will not always go through our query objects. Nothing is
  lost from the RECORD either way — the move writes an ordinary change row whose
  `diff` holds `[old, new]` as a real jsonb array, so a host that ever needs the
  departure query can add the `jsonb_path_ops` index on `diff` §4 anticipated
  without changing a stored byte.
- **Values are TEXT and NULLs are skipped.** `{"customer_id": 5}` and
  `{"customer_id": "5"}` do not match under `@>` and the symptom is an empty
  screen, so `AuditLog::Record.where_dimensions` is the ONE normalisation point
  on the read side — do not hand-roll `where("dimensions @> ?")` anywhere. A
  skipped NULL yields `NULL` rather than `'{}'`, which is what the partial index
  excludes on. Storing an explicit JSON null looks like it buys the negative
  query and does not: absence is already overloaded between "the FK was null" and
  "the row predates the declaration", so that query carries a permanent asterisk
  either way. "Which invoices have no department" is a current-state question;
  ask `invoices`.
- **Explicit only. There is no `dimensions: :auto`.** Sweeping in every `%_id`
  column is genuinely tempting and its failure mode is invisible: it takes
  `stripe_charge_id` and `external_uuid` along with the real associations, and a
  high-cardinality text id in a GIN index produces one entry per row — that
  index's worst case, arrived at silently, on the largest table in the database.
  An opt-in feature whose cost curve depends on columns nobody chose is not
  opt-in.
- **The GIN index carries `WHERE dimensions IS NOT NULL`, and that predicate is
  load-bearing rather than tidy.** GIN does not simply store nothing for a NULL —
  PostgreSQL records a placeholder (`GIN_CAT_NULL_ITEM`) — so an unqualified index
  puts every row of every non-adopting application into one enormous shared
  posting list serving a query nobody in that app can ask. Measured: unqualified,
  +15% insert and 4.3 MB of dead entries; qualified, 0.0% and 16 kB. The planner
  still chooses it because `@>` is strict and therefore implies the predicate —
  verified on 18.6, not assumed. `jsonb_path_ops` is endorsed HERE and rejected
  one column over on `diff` for one reason: `diff`'s question needs `?`, which
  that opclass does not support at all; a facet query only ever needs `@>`.
- **There is no GUC and no ambient dimension on CHANGE rows.** The obvious
  symmetry — a fifth `set_config` in `Context::STAMP_SQL` carrying a jsonb blob
  the trigger merges — would parse and merge per audited row on the hottest write
  path, and would give EVERY audited row in the database a non-NULL `dimensions`,
  so the partial index's predicate would exclude nothing and the index would be
  back to what the unqualified version was rejected for. Ambient dimensions do not
  merely cost more; they dismantle the mechanism that makes the feature free for
  the tables that opt out. An app that needs the tenant on the rows themselves
  wants §14's real `tenant_id` column instead.
- **`config.default_dimensions` takes NO ARGUMENTS, and that is what makes it a
  different mechanism from a registry `dimensions:` rather than a second spelling
  of one.** Nothing downstream can distinguish a key it supplied from a key the
  registry lifted, and nothing should. The distinction is entirely in what the
  value can VARY WITH: the registry reads the payload, so its facets differ
  between two events of one action; this reads application state, so they are
  identical for every event in a unit of work. Hand it the payload and it collapses
  into a registry declaration applied globally with worse discoverability. Two
  things follow and neither is available otherwise — it is a GUARANTEE that two
  events in one unit of work cannot disagree about the tenant, and it is memoised
  once per unit of work on `Current`. Widening the arity later is two lines, so
  this is not a one-way door.
- **`default_dimensions` NEVER re-raises**, and the precedent split is principled:
  `requires:` and `raise_on_subscriber_error` roll the transaction back because
  they protect the TRAIL; `LabelResolver` logs and renders FAILED because it is
  display. A facet is a convenience, so it follows `LabelResolver`. Rolling back
  an approved invoice because an app-version lookup raised would be indefensible.
- **`dimensions:` does not imply `requires:`**, and `spec/dummy` demonstrates BOTH
  shapes on purpose — `order.shipped` declares `customer_id` as a facet and does
  not require it, `customer.created` declares it in both. Do not "finish the job"
  by requiring the first: an entry that emits without a declared facet writes the
  event with no facet and raises nothing, which is the loose-by-default the whole
  feature is.
- **It is `config.dimension_filters`, not `config.dimensions`.** That spelling
  reads like the gem's DECLARATIVE options (`unaudited_tables`,
  `association_targets`) — plural nouns stating a fact the library acts on. This
  one is inert: it decides which filters a screen offers, and forgetting it costs
  a missing filter. Meanwhile `default_dimensions` one line above WRITES DATA onto
  every event permanently and non-retroactively, and would have read like the
  junior of the two. Consequence and appearance inverted — the `correlated_databases`
  mistake. Three settings in this feature are named `dimensions` and all three
  record data; one is named `filters` and does not.
- **The column list is checked against `information_schema.columns` at migration
  time, and it is the ONLY enforcement in the entire feature.** No coverage rule,
  no `required_dimensions`, no backfill, no raise anywhere else — a facet adds
  nothing to what is RECORDED, only to what is findable in one query, so a missing
  one is a question nobody asked rather than a hole in the log, and §16's forcing
  functions belong on the first kind. The typo check earns its exception because
  `deparment_id` otherwise records nothing forever and the symptom is a filter
  that returns nothing and never says why.
- **`AuditLog::DimensionTimeline` SUBCLASSES `Timeline` and swaps three private
  predicates (`changes_predicate`, `events_predicate`, `history_before?`) plus
  `anchor_for`.** Do not copy the union query. It has already gone wrong twice in
  this library's history in exactly the two ways a second copy invites: losing the
  events leg, and losing the `COALESCE` that stops every uncorrelated write
  collapsing into one NULL group. `history_before?` has to move with the other two
  or `older_than_window?` answers a different question from the page above it.
- **Both tables carry `dimensions` and BOTH LEGS filter their own column.** With
  the column on `audit_changes` alone the events leg would need
  `request_id IN (SELECT … FROM audit_changes …)` — a semi-join, evaluated twice,
  on the one query in the library that is already a union over two partitioned
  tables. A unit qualifies if EITHER matched.
- **An unfiltered `DimensionTimeline` compiles to `1 = 0`, never to `all`.** A
  cleared filter must not silently become a scan of the entire audit log dressed
  up as a result. `unfiltered?` is the discriminator and the screen renders a
  prompt.
- **`DimensionTimeline` is bounded by default (30 days) — the ONE place that
  diverges from `Timeline`'s "unbounded on purpose".** An unfiltered facet scan
  across 84 partitions where a facet matches a third of the table is genuinely
  slow, and the resolution is `RequestDrillDown`'s: bound generously, DISCLOSE the
  bound on the screen, offer the escape. Disclosed truncation is not invisible
  truncation. `range: nil` passed EXPLICITLY is unbounded, which is why the default
  lives in the method signature and not behind a `||=` — the same rule the
  retention and rollup keywords follow.
- **`anchor_for` derives which record an activity is "about" when the question was
  about a facet.** Event subject first, then the first change row that matched the
  facet, then the first change row. Anchoring on nothing was the alternative and is
  strictly worse: `mine` would be empty, so every entry would render with no field
  changes at all — "nothing changed" on a screen whose job is saying what did.
  Whatever is not the anchor becomes `also_touched`, so nothing is dropped.
- **The auditor UI's dimension screen HIDES its nav link when
  `dimension_filters` is empty, and the ROUTE still answers.** An app that declares
  no facets has a complete audit log and no question that screen could answer, so a
  nav item leading to an empty filter is worse than none — same discipline as
  `record_url` defaulting to nil. The route stays so a bookmarked URL explains
  itself instead of 404ing.
- **The dimension screen renders `records/_timeline_activities`, the same partial
  the record Timeline tab uses.** That sharing IS the proof of DESIGN §23's claim
  that a `DimensionTimeline` yields the same `Activity` a record timeline does. Its
  empty message is a local because "nothing recorded for this record" is a false
  statement on a faceted feed.
- **The retrofit migration re-installs the trigger function, and that half fails
  SILENTLY without it.** The function reads its facet list from `TG_ARGV[2]`, which
  the version installed before this feature does not look at — so declaring
  `dimensions:` against the old function passes the list to something that ignores
  it and records nothing, forever, with the column and index both in place and no
  error anywhere. `audit_log:dimensions` is therefore the complete upgrade path,
  not just an index build.
- **`DimensionIndex` gates its `DROP INDEX CONCURRENTLY` on `attached?`, and the
  reason is a Postgres property rather than care.** An ATTACHED child index cannot
  be dropped at all while its parent exists (`cannot drop index … because index …
  requires it`), so the INVALID-debris state is reachable only BEFORE the attach —
  verified on 18.6. Without the gate that line would try to drop working indexes on
  every re-run. Completeness is read from the catalog's `indisvalid` on the parent,
  never by counting partitions: §21.1's "never report success for work it did not
  do", enforced by Postgres instead of by arithmetic.
- **Retention, rollup, drain and freeze know nothing about this feature, and that
  is verified rather than hoped.** A partition created after the parent index
  exists inherits it, `rollup_year!`'s `LIKE … INCLUDING ALL` gives a yearly
  partition the facet index for free, a retired partition takes its indexes with
  it, and the drain's temp table needs none.
- **`Redaction` deliberately does NOT clear `dimensions`.** Facets are structure,
  like `changed_columns`, and structure survives an erasure — which is correct for
  `department_id` and wrong for anything that is itself personal data. Documented,
  not enforced, consistent with the rest of the feature: dimensions are ids and
  scope labels, not values.

### Disabling capture (DESIGN §25)

- **Capture is disabled by DETACHING the triggers, never by a flag the trigger
  function reads, and the loudness IS the feature.** A fifth early exit beside
  `audit.bypass` reading `ALTER DATABASE ... SET audit.disabled` is cheaper, needs
  no locks and survives a restart — and it would pass `rake audit_log:coverage`
  and the shared example while auditing nothing, because every trigger would still
  be attached and `structure.sql` byte-identical. `Bypass` gets away with a GUC
  because it is bounded by a block and narrates itself before opening; a durable
  flag is neither. Do not add one, and do not add `config.enabled = false` either
  — `retention_action`'s argument.
- **It is a GENERATOR, not a rake task, and that is not a style choice.** A rake
  task that drops triggers leaves capture off with `db/structure.sql` still
  claiming it is on: the schema dump becomes a lie and the one artifact that would
  have disclosed the change is the one that does not. A migration makes the six
  deleted `CREATE TRIGGER` lines and the marker comment one reviewable diff, and
  `schema_migrations` answers "when did capture stop".
- **The cycle is ONE reversible migration, indefinitely.** `db:migrate:up`
  disables, `db:migrate:down` resumes, either can be re-run. There is deliberately
  no re-disable generator — a ping-pong accumulating one migration per flip makes
  `db/migrate` a log of somebody's indecision.
- **The snapshot is READ from `pg_trigger.tgargs`, never reconstructed, and three
  details in the decode are load-bearing.** (1) `encode(tgargs, 'escape')` plus a
  split, not a regex over `pg_get_triggerdef` — the model name is an arbitrary
  string this library never validated, so parsing the rendered DDL has a quoting
  hole. (2) `tgnargs >= 3`, because the bytea's null terminator leaves a trailing
  empty string and without the guard every table looks as though it declared a
  facet. (3) The MERGED exclusion list is handed back whole as `exclude:` — it
  looks redundant with `default_excluded_columns` and is not, since
  `attach_audit_trigger` computes `(defaults + exclude).uniq`, so the merged list
  reproduces the original exactly AND still reproduces every exclusion if a
  default is later removed. Subtracting today's defaults reads better and puts
  `password_digest` back in the diffs the day somebody edits that config.
  `capture_spec` pins byte-identical `pg_get_triggerdef` across a full cycle.
- **The snapshot is written TWICE and neither copy is redundant.** In the
  migration as reviewable literals (the `bypass_allowlist` argument: reviewable in
  a diff before it runs), and in the marker because the migration can be squashed
  or absent from the checkout somebody is holding while capture is off — and by
  then the triggers are gone and the catalog cannot say what they were.
  `audit_log:enable` reads the marker and REFUSES on an empty snapshot rather than
  guessing model names from table names, which is `RecordLabel`'s sniffing refusal
  applied where it would mislabel `record_type` forever.
- **The marker is a table comment on the `audit_changes` PARENT**, in the
  `RETIRED_MARKER`/`ROLLUP_MARKER`/`FROZEN_MARKER` idiom. The parent is safe
  because `frozen_partitions` joins through `pg_inherits` and cannot see it. A
  corrupt payload reports "present, no detail" rather than raising — the
  unparseable-`RETIRED_MARKER` posture — and `snapshot` then returns empty, which
  is what makes the enable generator refuse.
- **Layer 2 keeps working, and that is what makes the gap legible rather than
  blank.** A paused app still writes `audit_events`, so the timeline keeps its
  narrative and loses the field changes beneath it. Do not "finish the job" by
  silencing layer 2 from the library side.
- **`Capture.disable!`/`enable!` RAISE when their registry entry is missing** —
  the one place here where an unregistered action is an error rather than a
  silence, because an unnarrated audit gap leaves the hole as the only evidence.
  That guard exposed a real pre-existing bug: `audit.bypass`,
  `audit.bypass_completed` and `audit.redaction` were registered ONLY by
  `spec/dummy`, so `Bypass`'s "the bypass logs itself" promise did not hold in any
  adopting app. All five library actions are now in the install template.
- **`audit.capture_resumed` declares no `requires:` on purpose**, so `spec/dummy`
  now has TWO deliberately-undeclared entries. `requires:` lists what an entry
  cannot RENDER without, and this one renders from nothing — `disabled_at` is
  absent whenever the marker was unreadable. `payload_contract_spec` pins both with
  a reason for each; do not "finish the job" on either.
- **`Coverage` gains a third state and STILL fails.** `capture_disabled?` exists
  so the report says "capture is disabled, since, because" instead of listing
  tables and advising attach migrations — which is the wrong repair, and
  `audit_log:trigger` SUCCEEDS while disabled, half-fixing it and leaving the
  marker over a schema that no longer matches. `ok?` is false and the shared
  example fails, checked FIRST because it changes what the next example means. Do
  not soften either.
- **`SET LOCAL lock_timeout`, `quote`d, and no advisory lock.** `DROP TRIGGER`
  takes ACCESS EXCLUSIVE (reads and writes) and `CREATE TRIGGER` SHARE ROW
  EXCLUSIVE (writes) — measured on 18.6 from `pg_locks`. `SET LOCAL` reverts with
  the migration's transaction and needs no restore; `maintenance_lock_timeout` is
  a PG interval string (`"5s"`), NOT a Duration, so `.in_milliseconds` raises.
  `Partitions::MAINTENANCE_LOCK_KEY` is deliberately not taken — it serialises
  three operations that corrupt each other, and this shares no state with them.
- **The DDL stays in the migration, using the published helpers.** `Capture` owns
  the marker and the narration only. A second copy of attach/detach inside
  `Capture` would be the `operation_name` mistake, and would lose
  `validate_identifiers!` and the `information_schema` facet check.
- **One genuinely lossy case, and it must stay stated.** A record created AND
  deleted inside the window leaves no trace it ever existed; everything else is a
  hole with visible edges (the next change still yields a full `[old, new]` pair
  off the live row, and a later DELETE still snapshots it). The generator prints
  it and the README states it, because a gap somebody accepted knowingly is a
  control and this is the part they need to accept it knowingly.
- **`Schema.uninstall!` is the OTHER thing** — it `DROP TABLE ... CASCADE`s both
  audit tables. The README names the asymmetry so nobody discovers which one they
  ran.

### The starter stylesheet (DESIGN §21.4)

- **The engine ships NO CSS, and that follows from `parent_controller` rather
  than being a gap.** Its screens render inside the HOST's layout, so a
  stylesheet the gem loaded would arrive uninvited on somebody else's page. Do
  not add one, and do not add an asset the engine links.
- **`audit_log:views:css` writes the starter stylesheet COMMENTED OUT.** Live on
  landing is the same imposition one step removed — the host would find out by
  seeing their screens change. Inert, it is a proposal. `audit_log:install`
  invokes the same generator rather than re-spelling it, so there is one template
  and one set of instructions.
- **ONE explainer, then ONE block comment round the whole stylesheet.** Enabling
  is deleting two lines, or one editor keystroke on the selected block. The first
  version wrapped each of the twelve sections separately — selective enabling
  nobody asked for, at the cost of making the ordinary case a `sed` with escaped
  delimiters. Do not re-section it. `css_generator_spec` pins that there is
  exactly one wrapping block, because the gesture depends on it.
- **The block must contain NO COMMENTS AT ALL, and no wrapped titles.** One
  closing delimiter inside it ends the block early and leaves the rest of the
  stylesheet live, un-enabled and unannounced. The section map lives in the
  explainer above. Under the old sectioned layout this bit twice — an inner
  comment, and a section title that wrapped onto a second line leaving prose
  where a selector belongs.
- **Every selector is scoped under `.audit-log`, and the 11 top-level templates
  are wrapped in it for exactly that.** The screens use generic class names
  (`.card`, `.note`, `.new`, `.old`, `.grid`), which is harmless until a host
  uncomments a stylesheet targeting them bare. Do not remove the wrapper, and do
  not add an unscoped rule — the spec fails on one.
- **`.grid` is the engine's class for a data TABLE, not for CSS grid.** The first
  draft gave it `display: grid` and broke every table on every screen. Found by
  rendering the previews and looking; `spec/preview.rb` now inlines the enabled
  stylesheet so the next such bug is visible too.
- **Dark mode is a SEPARATE section and sets a background as well as a
  foreground.** Flipping only the foreground paints light text onto a light host
  page. Separate because enabling it makes the screens follow the reader's system
  setting rather than the app's, which on a light-only app is a dark panel in a
  light page.
- **Colour is never the only signal** — an ABSENCE reads muted rather than red,
  because "there was nothing here" is not a before-or-after fact and colouring it
  as a loss reports a field that never had a value as one that lost one. Badges
  carry their own text; a redaction says so in words.
- **The CSS is `../audit-log-demo`'s `application.css`, ported and scoped** — no
  framework, no Tailwind; it was arrived at by rendering these screens and fixing
  what broke. Five rules in it look odd and are load-bearing, and the explainer
  lists them because the block cannot hold comments: the `display: contents`
  field grid, its repeat inside `.record-list` (an equal-specificity rule above
  it wins on source order otherwise), the un-hung third-level summary, the
  border-drawn triangle, and the rail dot that carries `kind`.
- **The reference app CONSUMES this template — it does not hold a second copy.**
  Its `application.css` keeps only what its own pages need and what the generated
  activity feed reads (250 lines to 129); `/audit` is styled by the generated
  file, enabled and linked. Same workflow as the activity templates: change this
  template, re-generate the demo's copy, look at both. Do not re-add
  `.audit-nav`, `.tabs`, `.date-filter`, `.cards`, `.export` or `.timeline` to
  that file — a header comment there says so.
- **The demo DELETES the dark-mode block from its enabled copy**, because its own
  chrome is light only and following the reader's system setting made the audit
  region a dark panel inside a light page. That is the header's own advice, taken
  — and it is what the guidance is for, so do not "fix" the demo by putting it
  back.

### Documentation for coding agents (DESIGN §24)

- **`llms.txt` is in `spec.files` and `CLAUDE.md` is deliberately not, and both
  halves matter.** The whole mechanism is that an agent in a host app resolves
  `bundle info audit_log --path` and reads what is there, so a document left out of
  the gem is one no adopter can reach. `CLAUDE.md` stays out because it is the rule
  list for somebody CHANGING the library — shipped into a host app it hands an agent
  the rules for the wrong job. `readme_spec` pins both directions, plus every README
  anchor `llms.txt` routes to and every `§n` it cites: it is the one document nobody
  reads while working, so every way it can rot is invisible.
- **The generated `.claude/skills/audit-log/SKILL.md` is a POINTER and must stay
  one.** It lives in somebody else's repository, cannot be corrected by a gem
  release, and would go stale silently while reading with full authority. It carries
  the resolution command, the routing sentence, and only genuinely local facts (the
  mount path, whether a coverage spec exists). Its four warnings are the deliberate
  exception — a "why" that prevents a MISUSE, §22's rule — and each is an
  architectural invariant that cannot change without a major version. Do not add a
  fifth that is API detail, and do not let it grow a version-specific fact.
- **Create-once, host-owned, no gem-side dependency, and no "your skill is out of
  date" check** — §21.3's boundary exactly, applied to a second kind of generated
  file. Nothing in the library may learn whether it exists.
- **No `AGENTS.md` is written or appended, and no MCP server.** `AGENTS.md` is a
  single root file the host owns entirely; appending to it is the
  `config/locales/en.yml` case. The README prints the one line and leaves it to the
  operator. An MCP server is a process and a transport for content already sitting in
  the bundle — the gap was discovery of static files.

Every browse screen is keyset-paginated through `AuditLog::Pagination`
(DESIGN §11.0 Rule 2). **Do not add `.limit` to a screen's scope** — a limit
baked below the controller is invisible to the page rendering it, which is
exactly how an audit view comes to under-report without saying so. The dashboard
is the deliberate exception: its lists are "10 most recent" widgets, not
browsable results. `config.page_size` is the only knob.
- **`AuditLog::Pagination::FULL_PRECISION` is load-bearing.** The keyset cursor is
  serialized with `to_json`, and ActiveSupport renders a `Time` at
  `time_precision` **3** — milliseconds — while `occurred_at` is
  `clock_timestamp()`, microseconds. Without the lambda the cursor names an
  instant just before the row it came from and the next page silently skips
  everything in the gap. It presents as a rare flake, not as an error.
  `spec/audit_log/pagination_spec.rb` pins it with six rows inside one
  millisecond; that example returns 2 of 6 rows if the lambda is removed.

## The activity generator

**`DESIGN.md` §21 is the authority on the three generators it covers**; §21.3 is
this one and §21.4 is `audit_log:views:css`, the other thing under `views:`. The fourth, `audit_log:dimensions`, is a retrofit path and its reasoning
lives in §23 with the rest of that feature; the fifth and sixth,
`audit_log:disable` and `audit_log:enable`, live in §25 with theirs. `audit_log:install`'s agent-skill step
is §24's, not §21's — it is a documentation-distribution decision that happens to be
implemented in a generator.
Everything below is the terse copy.

**It is `audit_log:views:activity`, under a `views:` namespace, and the namespace
is the point.** `audit_log:activity` reads like `rails g model Activity` — as
though it created an Activity model — when what it does is copy starter views
into a host app. Any generator added here that writes presentational code into a
host app belongs under `views:` for the same reason. The class must live at
`AuditLog::Generators::Views::ActivityGenerator` for Rails to derive that
namespace; `activity_generator_spec` would fail on the require path if it moved.


**What this generates is OPTIONAL and the host owns it.** Two different things
ship from this repo and the boundary matters: the library and the auditor UI at
`/audit` are *served by the engine* — not copied, not the host's to maintain, and
they upgrade with the gem. What `audit_log:views:activity` writes goes *into the host
app* and is theirs outright: never re-generated, never upgraded, no markup
lock-in, and nothing in the gem depends on it existing. Do not add a gem-side
dependency on a generated file, and do not add a "check your generated views are
current" mechanism — that would turn owned code back into managed code.


`rails generate audit_log:views:activity Order Product Customer` emits the reference
app's timeline UI into a host app. It takes any number of models, and running it
again later adds more — that second run is the one to think about when changing
anything here, because it meets files the host has since edited.

What is load-bearing about it:

- **The templates ARE the reference app's files.** `../audit-log-demo` is
  regenerated from them and differs by exactly one line — its
  `audit_activity_visible?` returns `current_user&.manager?` where the template
  returns `false`. Change a template, regenerate the demo, run its suite. Two
  hand-maintained copies is the failure this arrangement exists to prevent.
- **View templates emit ERB THROUGH ERB.** Every runtime tag is escaped `<%%`,
  and only the class slots (`<%= css(:card) %>`) are generate-time. Get it wrong
  and you ship a view that renders its own source, which reads as a styling bug.
  `activity_generator_spec` compiles every generated `.erb`, and asserts
  separately that the runtime tags arrived as ERB with no `<%%` left in them.
- **`audit_activity_visible?` is generated as `false`.** Never change that to
  `true` "for convenience". It is the difference between a host that has decided
  who may read audit diffs and one that has published them by default.
- **`VIEWABLE` is checked BEFORE `constantize`, and that order is the point.**
  `/activity/User/1` is a URL anybody can type. Constantizing a path parameter is
  untidy anywhere; on a page that renders audit diffs it reads the history of a
  model the host never meant to expose. The generator also refuses to run with no
  models rather than emitting an empty allowlist.
- **The locale strings get their own file**, never an edit to the host's
  `config/locales/en.yml`. Nothing generated should be able to clobber a host key.
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
| `add_audit_dimension_index` / `remove_audit_dimension_index` | published migration API, for the tuning step when one facet turns out to be on every screen (DESIGN §23) |
| `DimensionIndex.status` | for an operator asking "did that retrofit finish?" without re-running the migration |

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

`dimensions:` is optional on that same line and records host-defined facets from
the row — see "Dimensions" above. Declaring none costs the table nothing.

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
bin/rails audit_log:partitions         # DAILY CRON. create missing months, freeze newly closed ones
bin/rails audit_log:coverage           # fail if a table lacks a trigger and a reason
bin/rails audit_log:reconcile          # correlated changes with no registered action
bin/rails audit_log:redact             # RECORD=Type:id REASON=… [FIELDS=a,b] [DRY_RUN=1]
bin/rails audit_log:benchmark ROWS=n   # generate volume, EXPLAIN the canonical queries
bin/rails audit_log:benchmark_cleanup  # remove the synthetic rows

bin/rails audit_log:partitions:drain_default             # rows stranded in the default partition
bin/rails audit_log:partitions:rollup                    # closed years → yearly partitions (DRY_RUN=1)
bin/rails audit_log:partitions:retention                 # DETACH + mark retired. never drops (DRY_RUN=1)
bin/rails audit_log:partitions:export_retired DIR=…      # every retired partition → gzipped CSV + manifest
bin/rails audit_log:partitions:drop_retired              # drop marked partitions, no export check
bin/rails audit_log:partitions:export_and_drop_retired DIR=…  # the recommended disposal path
bin/rails audit_log:partitions:freeze                    # manual catch-up; partitions does it daily
```

The `partitions:` namespace shares its name with the daily `partitions` task —
deliberate, and verified in a real app rather than assumed. Rake keys tasks by
full name string, so the one cron line whose failure is a write-path outage never
had to change.

The README carries the full reference — what each does, why, and when. Keep the
two in step: a task added here and not there is a task nobody runs.

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
bundle exec rspec                         # 508 examples, against spec/dummy
bundle exec rspec spec/audit_log          # the library proper
bundle exec rspec spec/requests           # the auditor UI and the CSV export
bundle exec rspec spec/preview.rb         # dev tool: renders 19 screens to spec/dummy/public/
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
| `css_generator_spec` | the starter stylesheet stops being inert as shipped, stops being valid CSS once enabled, or grows a rule that would reach past `.audit-log` into the host's own markup |
| `time_display_spec` | a timestamp loses its date, its year or its zone, or the host's own I18n formatting reaches an audit screen |
| `identity_spec` | a screen hand-spells a recorded identity, so two tabs describe one fact differently — or the `#` that a host app uses for its own numbering comes back |
| `readme_spec` | the README's contents table drifts from its headings, an internal link dangles, a rake task exists that the docs never mention — **nested ones included; the old two-space regex checked 6 of 13 and skipped every retention task** — or `llms.txt` routes into a heading that is gone, cites a dead `§n`, or falls out of `spec.files` |
| `record_timeline_spec` | an unsubjected action vanishes from a record's narrative, or a capped section does not admit it is capped |
| `timeline_spec` | the published host-facing contract changes shape, a unit of work is dropped or repeated across pages, an event that wrote no change row falls off the timeline, or `headline` starts inventing sentences |
| `install_generator_spec` | the ControllerContext include lands ahead of authentication, or a skipped step reports success |
| `event_transport_spec` | layer 2 silently stops emitting on one end of `rails ~> 8.0`, or takes the wrong branch for the Rails it is on |
| `schema_isolation_spec` | the library reverts to assuming `public` — rows filed in the wrong schema's table, or a provisioning check answered from another schema's state |
| `dimensions_spec` | a facet stops reaching the writes no callback sees, a faceted feed silently answers a narrower question than its screen claims, or a cleared filter turns into a scan of the whole log |
| `capture_spec` | capture stops without saying so, or resumes under different arguments than it had — a `record_type` naming the wrong model, an exclusion silently dropped so a password column re-enters the diffs |

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

Two workflows. `release.yml` turns a pushed `v*` tag into a GitHub Release with
that version's CHANGELOG section as the body, and exists because a tag and a
Release are different objects: pushing a tag creates the first and never the
second. This repository had five tags and two Releases, so GitHub labelled 0.2.0
"Latest" for three releases and `/releases/latest` answered with it — nothing
broken, nothing saying so. Three things about it are load-bearing:

- **It refuses when the tag and `version.rb` disagree.** The README pins by tag,
  so `v0.5.0` on a tree still saying `0.4.0` hands an adopter 0.4.0's code under
  0.5.0's notes. This is the only place that can notice.
- **`.github/scripts/changelog-section` is ONE extractor, used by the workflow and
  by a human backfilling by hand.** Two spellings of "the body of a release" drift,
  and the drift is a release note that does not match its changelog. It exits
  non-zero on a missing or empty section rather than printing nothing — an empty
  release note looks deliberate and says nothing.
- **It does not publish the gem, and must not.** `allowed_push_host` is a
  deliberate non-host so `gem push` fails; this is release NOTES only. It does
  repeat the warning-free `gem build` gate, because a tag can be pushed to a
  commit CI never ran.

`.github/workflows/ci.yml`, on every push and pull request. It exists because the
forcing functions above force nothing if they only run when someone remembers.

Two parallel legs, and the pairing is deliberate:

| Leg | Why |
|---|---|
| Ruby **3.3** | the floor `required_ruby_version` claims. Testing only the development Ruby leaves that claim unverified — and it *was* wrong: the gemspec said 3.2 until this leg failed on `SecureRandom.uuid_v7` being 3.3+. |
| Ruby **4.0.6** | what the library is developed on |
| PostgreSQL **16** | the floor DESIGN §20 claims, for the same reason the 3.3 leg exists: a floor nothing runs against is a guess |
| PostgreSQL **18** | what the library is developed on, and what §20.2 records real wins from |

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

**Both Rails legs are exercised, and they take different code paths.** Verified
2026-09-01 by running the whole suite on each: 508 examples pass on 8.0.5.1 and on
8.1.3.1. `Rails.respond_to?(:event)` is FALSE on 8.0 and TRUE on 8.1, so
`AuditLog.notify`'s fallback runs on one leg and `Rails.event` on the other —
`event_transport_spec` asserts which branch it is on rather than assuming.
`ActiveRecord::Transaction`'s public API is identical on both
(`after_commit`, `after_rollback`, `closed?`, `open?`, `uuid`), which is why
`audited` promises exactly those.

## Designed but not yet built

Nothing. **§25 (disabling capture) shipped 2026-09-01** — its terse entries are
under "Disabling capture" above. **§23 (dimensions) shipped 2026-09-01** — its terse entries are in
"Things that look like bugs but are deliberate" above, under "Dimensions", and its
staged README appendix is now the README's "Dimensions" section. §23 keeps the
reasoning and its rejected alternatives; read those before changing anything in
the feature, because several were designed completely before being rejected — an
`OLD ∪ NEW` array encoding, an ambient GUC on the trigger, `dimensions: :auto`,
gating the column behind the opt-in migration — and each reads like an obvious
improvement without the reason it lost. The costs in it are measured, not
estimated.

When something else reaches the same stage, this section is where it goes, and the
two rules that governed §23 apply to it: the terse entries move into the
deliberate-decisions list, and a staged README appendix moves into `README.md`
with the `<!-- README-DRAFT heading="..." -->` marker deleted from `DESIGN.md` —
`readme_spec` fails while both copies exist, because two copies of the same user
documentation drift.

## Deliberately not implemented

Per [`DESIGN.md`](DESIGN.md) §12, §13 and the reference app's `ROLLOUT.md` — all
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
