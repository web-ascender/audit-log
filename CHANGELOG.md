# Changelog

Notable changes to `audit_log`. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

## Unreleased

## 0.6.2 — 2026-09-10

Timestamps on the auditor screens. Nothing about capture, storage or the schema
changes, and stored values remain UTC by construction — this is entirely about
what a screen shows. An application on the defaults gets the fix and the
reader-local rendering with no configuration.

### Fixed

- **Timestamps on the auditor screens showed no date in some applications, and
  never showed the year in any of them.** The helper rendered
  `l(time, format: :short)`, which reads the *host's* `time.formats.short` — so
  the format of every timestamp in the auditor UI was decided by one of your
  I18n keys. An app that had set that key to a time-only format got audit screens
  with no date at all, and Rails' own default (`%d %b %H:%M`) omits the year on a
  log kept for seven years. The format is the library's own now, and the zone is
  always named, and the date is ISO-ordered so it reads the same in every
  language: `2026-09-10 13:06 UTC`.

### Added

- **Timestamps render in the reader's own timezone**, resolved in their browser
  through `Intl.DateTimeFormat` — no date library, and no dependency added to
  your app. It is progressive enhancement in that direction on purpose: the
  server renders a complete labelled UTC timestamp and a small inline script
  re-renders it locally, so no JavaScript, a blocked script or a strict Content
  Security Policy leaves a correct timestamp rather than a blank column. The
  script carries your CSP nonce when you have a policy.

  `datetime` and `title` keep the recorded instant at microsecond precision
  whatever the visible text says, so a local rendering never becomes the only
  account of when something happened. The CSV export is untouched.

- **`config.timestamp_locale`** — whose *conventions* the reader-local timestamp
  follows: field order, month name, and the 12-or-24-hour clock. `nil` (default)
  is the reader's own locale; `"en-US"` is that house style for every reader;
  `"en-US-u-hc-h23"` is American field order on a 24-hour clock.

  A **BCP-47 tag and not a format string**, deliberately. A `strftime` string is
  what this release stopped taking from your I18n, and it can drop the year or
  the zone label with nothing reporting it. A locale tag gives the same control,
  cannot express "no year", and drives `Intl` natively. The field set stays the
  library's — date, year, time and zone are always all present. A malformed tag
  is refused at boot; one a particular browser dislikes falls back to the
  reader's own locale rather than to no conversion.

- **`config.display_time_zone`** — `:viewer` (default) or `:utc`. The engine
  refuses to boot on any other value rather than falling back to UTC silently.
  The application's own `Time.zone` is deliberately not an option: it is neither
  the reader's zone nor the recorded one. DESIGN §4.

## 0.6.1 — 2026-09-10

The starter stylesheet only. No library code changed, so an application that has
already generated and edited its own copy is unaffected — the file is
create-once and never re-generated. A new install gets the stylesheet below.

### Changed

- **The starter stylesheet is one block comment now, not twelve.** Enabling it is
  deleting two lines — the bare opener under the explainer, and the file's last
  line — or selecting that block and pressing the editor's toggle-comment key.
  0.6.0 wrapped each section separately, which bought selective enabling nobody
  asked for and made the ordinary case a `sed` incantation with escaped
  delimiters. The section map moved into the explainer, since a comment inside
  the block would close it early. Enabled output is byte-for-byte what it was.

- The generator and the README now show `@import "audit_log";` in
  `application.scss` as the Sass/importmap way to load it, alongside the
  Propshaft and Sprockets lines.

- **The starter stylesheet is now the reference app's, ported and scoped.** The
  first version was written from the class inventory; `../audit-log-demo`'s
  hand-written `application.css` had been arrived at by rendering these screens
  and fixing what broke, and looked considerably better. It brings a warmer
  palette, `table.grid` as a bordered panel with small-caps headers, coloured
  before/after text in place of tinted cells, and a timeline rail whose dot
  carries `kind`. Five of its rules look odd and are load-bearing — the
  `display: contents` field grid chief among them — and the explainer at the top
  of the file says which and why. Fifteen custom properties, a dark palette to
  match, and two breakpoints. DESIGN §21.4.

  The reference app now consumes the generated file instead of holding its own
  copy — its `application.css` went from 250 lines to 129 — which is the same
  arrangement the generated activity views already have, and for the same
  reason. It also deletes the dark-mode block from its enabled copy, because its
  own chrome is light only: the header's advice, taken.

## 0.6.0 — 2026-09-09

No migration, and nothing to do on upgrade. One rendering change reaches rows
already written, and one reaches rows written from here on — both under Changed.

### Added

- **A starter stylesheet for the auditor UI, written into the host application
  commented out.** `audit_log:install` now writes
  `app/assets/stylesheets/audit_log.css`, and `audit_log:views:css` writes it on
  its own for an app that skipped it. As generated it is a no-op — every rule
  sits inside a block comment — so it changes nothing until somebody deletes the
  delimiter lines, which the generator prints and the file's header repeats.
  `--skip-css` opts out.

  The engine still ships no CSS of its own and will not: its screens render
  inside the host's layout, so a stylesheet the gem loaded would arrive uninvited
  on a page the host designed. This is a proposal the host owns the moment it
  lands — never re-generated, and nothing in the gem checks whether it exists.

  Sections are separately enableable: palette, layout, nav, tables,
  before-and-after values, association labels, badges, cards, disclosures, notes,
  filters, and dark mode. Dark mode is separate on purpose, because enabling it
  makes the screens follow the reader's system setting rather than the
  application's. Colour is never the only signal in it. DESIGN §21.4.

- The engine's 11 top-level screens are now wrapped in `<div class="audit-log">`,
  which is what lets every generated rule be scoped and reach nothing of the
  host's own. Its class names are otherwise generic enough to collide — `.card`,
  `.note`, `.new`, `.old`.

### Changed

- **A recorded identity now reads `Order (id: 6064)`, not `Order #6064`.** The
  `#` prefix is what host applications overwhelmingly use for an identifier of
  their own — an order number, an invoice number, a ticket reference — so on an
  audit screen, beside a live-resolved label, a reader could not tell which
  number the log had actually recorded. The annotation now names itself.

  New `AuditLog::Identity` is the one definition, in three forms: `annotation(id)`
  where the column has already named the type (`(id: 51)`, unchanged, as diff
  cells have always rendered it), `for(type, id)` standalone, and
  `labelled(label, type, id)` → `Grommet 10mm (Product id: 51)`. Every screen,
  the redact task and both generator templates go through it; the same
  interpolation had been hand-spelled in seven places, and the Changes tab and
  the Timeline tab of one record screen had already drifted apart because of it.

  **Two of those sites store rather than render.**
  `Configuration#default_actor_label` snapshots into the `actor_label` columns,
  and the `audit.redaction` summary in the install template is frozen at emit
  time. Rows written before this change keep the spelling they were written with
  — that is what a snapshot means, and there is deliberately no migration that
  rewrites them — so an app on the default resolver will see a mixed actor
  column from here on. The other six render at display time and pick the new
  spelling up for existing rows immediately.

  A host that generated the optional activity views keeps its own copy of the old
  heading until it edits it: those files are host-owned and never re-generated.
  There is deliberately no `config.identity_format`. DESIGN §11.8.

## 0.5.2 — 2026-09-09

Documentation and reporting only. No behaviour change to either capture layer.

### Changed

- **`audit_log:coverage` leads its finding with a count, and sorts the tables.**
  `23 untracked tables: ...` rather than `Untracked tables: ...`, alphabetically
  rather than in catalog order. Both are for the reader of a CI log, where that
  list is the part that scrolls: shown from the tail, a forty-table wall reads as
  a handful of findings, and creation order is not what somebody scanning for the
  table they just added is using.

  The sort is in `AuditLog::Coverage#missing`, so the rake task, the
  capture-disabled report and any host calling `missing` directly share it. The
  count is spelled in the shared example in `audit_log/rspec` too — that message
  is a second rendering of the same finding, and this class exists so the two
  cannot disagree.

- **The install template's `unaudited_tables` block carries commented examples**
  for Active Storage, Ahoy, PaperTrail's `versions` and the PostGIS reference
  tables (`us_lex`, `us_gaz`, `us_rules`, `spatial_ref_sys`).

  They stay commented, and they stay in the host's initializer rather than
  becoming gem defaults. The four defaults are tables no application could want
  audited; `active_storage_attachments` records who attached which file to which
  record, which is a real auditor question in a document-heavy app, and a default
  exemption would mean coverage never asks it again — silently, in every adopting
  app. That is the one thing the forcing function exists to prevent, so the group
  carries a note saying so.

- **`--exclude` is documented as space-separated** in the `audit_log:trigger`
  options table. It is a Thor `type: :array`, so `--exclude=a,b` arrives as one
  column name `a,b`, matches nothing, and leaves both columns in the diff while
  the generator reports success.

## 0.5.1 — 2026-09-01

### Changed

- **The default `actor_label_resolver` now tries `to_audit_label` before
  `to_label`**, the head `AuditLog::RecordLabel` has always used. The tails still
  differ on purpose — `RecordLabel` ends in `nil` so association labelling stays
  opt-in, this one ends in `Class #id` because the actor column would otherwise be
  blank — but one hook now answers "what should an auditor see" wherever a model
  appears in the log, and it matters more here, where the string is snapshotted
  onto every row rather than resolved live beside an id that stays visible.

  Affects only an app on the **default** resolver whose actor model defines
  `to_audit_label`, and is not retroactive. `config.actor_label_resolver =
  ->(a) { a.to_label }` keeps the old behaviour. DESIGN §11.8.

### Added

- **`.github/workflows/release.yml`** — a pushed `v*` tag now becomes a GitHub
  Release with that version's CHANGELOG section as the body, via the same
  `.github/scripts/changelog-section` extractor a human uses by hand. A tag and a
  Release are different objects and pushing the first never creates the second,
  which is how this repository reached five tags with two Releases. It refuses
  when the tag and `version.rb` disagree, and does **not** run `gem push`.

- `spec/audit_log/actor_label_spec.rb` — `AuditLog::ActorLabel` had no spec, and
  `spec/dummy` overrides the resolver, so the default chain was untested from both
  directions.

## 0.5.0 — 2026-09-01

No breaking changes. An application that adds nothing sees no behaviour change,
with one exception noted under Fixed.

### Added

- **Disabling capture, and resuming it.** `rails generate audit_log:disable
  --reason="..."` writes one reversible migration that detaches every audit
  trigger, keeping the audit tables, every partition, every row and the auditor
  UI. `db:migrate:down` re-attaches exactly what was there, and that one migration
  is the whole cycle — `up` disables, `down` resumes, either can be re-run.
  `audit_log:enable` is the recovery path for when the migration has been squashed
  or deleted, rebuilding from a marker on `audit_changes`.

  It detaches rather than setting a flag the trigger reads, because a flag would
  satisfy `audit_log:coverage` while auditing nothing. So `AuditLog::Coverage`
  gains `capture_disabled?` and reports that state instead of advising attach
  migrations — and still fails, on purpose. Layer 2 keeps writing `audit_events`;
  there is deliberately no `config.enabled = false`. Both directions emit
  `audit.capture_disabled` / `audit.capture_resumed` and raise rather than emit
  nothing if those are unregistered. New `AuditLog::Capture`. DESIGN §25.

- **`Timeline::TouchedRecord#field_changes`** — the other records a unit of work
  touched now carry their own before-and-after, not only which columns moved.
  Costs no query (the change set is already hydrated) and is lazy. Additive to the
  published contract: `as_json` gains a nested `field_changes` array. The engine's
  Timeline tab and the `audit_log:views:activity` templates both render it,
  collapsed. DESIGN §11.2b.

- **Documentation for coding agents.** The gem packages `llms.txt`, a summary and
  a routing table into `README.md` and `DESIGN.md` as file paths inside the
  installed gem. `audit_log:install` writes `.claude/skills/audit-log/SKILL.md`
  into the host — a pointer, create-once, host-owned, never regenerated;
  `--skip-skill` declines it. `CLAUDE.md` is deliberately not packaged. DESIGN §24.

### Fixed

- **The library's own actions are now registered by `audit_log:install`.**
  `audit.bypass`, `audit.bypass_completed` and `audit.redaction` were registered
  only by the dummy app, and an unregistered action is a silent no-op in
  `EventSubscriber` — so `AuditLog::Bypass`'s documented promise that *"the bypass
  logs itself"* did not hold in any adopting application, and a redaction wrote no
  `audit.redaction` row.

  **This is the one thing to do on upgrade.** A new install gets all five actions;
  an existing app should copy the block from the generator's initializer template.
  Without it the bypass and redaction go on working and go on not narrating
  themselves, and `audit_log:disable` refuses to run.

- **`readme_spec`'s undocumented-task guard was checking 6 of 13 tasks.** It
  matched two spaces of indent, so the entire `audit_log:partitions:` namespace —
  every retention and disposal task — was invisible to it. All seven were
  documented, so it never failed; it was not checking. It now walks the namespace
  stack, with a floor assertion so a broken walk cannot pass by finding nothing.

### Changed

- **`README.md` documents redaction and `AuditLog.without_logging`**, which had
  between them one row of a config table and one row of the rake-task table. New
  "Redacting values under an erasure request" and "Bypassing the log for a bulk
  load" sections under Advanced, beside "Stopping auditing" — three escalating
  scopes, cross-linked.

- **Corrected stale `DESIGN.md` claims that contradicted the other two documents.**
  §2.2 and §16 said CI tested Rails 8.1 only and that the Rails 8.0 leg was
  missing, both untrue since 0.4.0; §2.2 listed
  `config.active_job.enqueue_after_transaction_commit` as required of the host,
  which §6.4 of the same document says does nothing. Plus an editorial pass over
  the README: repetition cut, one stale forward reference removed, rationale moved
  to DESIGN §5.2, and the prose rewrapped to 80 columns throughout.

## 0.4.0 — 2026-09-01

### Added

- **Dimensions — host-defined facets, so an app can ask "everything that happened
  to invoices in department 5".** A `dimensions jsonb` column on both audit
  tables, filled from two sources that mirror the two layers: the trigger reads
  declared COLUMNS off the row that changed, so facets reach `update_all`,
  `delete_all`, raw SQL, a database cascade and a console session; and
  `EventSubscriber` lifts declared KEYS out of a completed payload, so facets
  reach a unit of work whose writes landed in a table that declares none. A unit
  qualifies if either matched.

  ```ruby
  attach_audit_trigger :invoices, model: "Invoice", dimensions: %i[department_id]

  AuditLog::Registry.register "invoice.approved", dimensions: %i[region], ...
  config.default_dimensions = -> { { app_version: AppVersion.current } }
  ```

  Query with `AuditLog::DimensionTimeline`, which is `Timeline` with the record
  predicate swapped and yields the same `Activity` value objects, or with
  `where_dimensions` on either relation. `config.dimension_filters` adds a filter
  to the auditor UI at `/audit/dimensions`.

  **Entirely optional, and an application that declares no facet pays nothing.**
  The GIN index is partial on `dimensions IS NOT NULL`, so it excludes every row
  of every non-adopting table permanently and at write time; the trigger's
  extraction sits behind `TG_ARGV[2] IS NOT NULL`. The column itself costs
  `audit_events` nothing and `audit_changes` 8 bytes a row (+0.54% heap),
  measured and accepted so that there is one trigger function rather than two.

  **Three limits are documented rather than discovered**, because each is a screen
  that renders fine while answering a narrower question: it is not retroactive, a
  conjunction has to fit on one row, and a row is filed under the value it held
  *after* the change. `DimensionTimeline` is consequently the one query object
  bounded by default (30 days), and it discloses the bound.

  See the README's "Dimensions" section and DESIGN §23, which keeps the
  measurements and the rejected alternatives — an `OLD ∪ NEW` array encoding, an
  ambient GUC on the trigger, `dimensions: :auto`, and gating the column behind
  the opt-in migration.

- **`rails generate audit_log:dimensions`** — the retrofit path, for an
  application installed before the above. It adds the column, **re-installs the
  trigger function** so it reads facet lists, and builds the facet index one
  partition at a time with `CREATE INDEX CONCURRENTLY` (refused outright on a
  partitioned table), asserting the catalog's own `indisvalid` rather than
  counting partitions. Safe to re-run after an interruption. A new install needs
  none of it.

- **`AuditLog.audited(action, on:, **identity) { |audit| … }`** — sugar for the
  canonical layer-2 call site, `transaction do ... AuditLog.notify ... end`. It
  opens the transaction, runs the block, and emits as the last statement inside
  it, so both directions of R3 are unchanged: a raise never reaches the emit, and
  a failed emit rolls the writes back. Returns the block's value.

  **The payload is built in two slots.** Keyword arguments are evaluated before
  the block, which is right for identity and inputs and silently wrong for
  outcomes — a total recalculated by the block, a tracking number for a record it
  has not created yet. Those go through the yielded `AuditLog::Payload`
  (`audit[:k] = v`, `audit.merge!(k: v)`, `audit.merge!({…})`). A key set in both
  slots raises, with a message naming which one to remove it from.

  `AuditLog::Payload` wraps a Hash rather than subclassing one, so `delete`,
  `clear` and `replace` are not part of what a block may do to an audit payload.
  `merge` without the bang raises: Ruby's convention would have it build a hash
  and discard it, emitting the event without those keys.

  Purely additive. The explicit `transaction` + `notify` form is unchanged, not
  deprecated, and remains the option when several notifies belong to one
  transaction. See DESIGN §7 and the README.

- **`AuditLog.audited` now yields the `ActiveRecord::Transaction`** as a second
  block argument, accepts `transaction:` options passed through to
  `ActiveRecord::Base.transaction`, and raises on an `ActiveRecord::Rollback` it
  could not honour. It has always joined a caller's open transaction — that is
  the only way Rails allows one to be handed over — but a joined transaction
  swallows `ActiveRecord::Rollback`, and the sugar hides the nesting. Left
  unguarded that committed the writes, emitted no event, and returned `nil` as
  though it had rolled back. Yielding the transaction lets a caller use Rails'
  transaction callbacks without opening one of its own; when joined it is their
  transaction, so callbacks fire on their outermost commit.

- **`AuditLog::Registry.register requires:`** — an optional payload contract per
  action. The keys a call site passes and the `p[...]` reads in the entry were
  checked by nothing, and a typo on either side rendered a gap in a sentence that
  is frozen at emit time and can never be repaired. Declared, a missing key
  raises `AuditLog::MissingPayloadKeys` from `EventSubscriber#emit` — the one
  point `notify`, `audited` and a bare `Rails.event.notify` all cross, and inside
  the caller's transaction, so the change rolls back rather than committing
  beside a holed sentence.

  Opt-in per entry: without `requires:` an action behaves exactly as before, so
  the raise is only reachable where somebody wrote a contract. Extra keys pass
  and are still stored. The check is key presence, not value presence — a
  deliberate `nil` counts as supplied, since `metadata` is stored `.compact`ed
  and would otherwise be indistinguishable from a forgotten key.

## 0.3.0 — 2026-08-30

**Two configuration surfaces were quietly lying, and this release stops both.**
Neither failure raised, logged, or degraded a screen — the ordinary shape of an
under-report, which is the thing this library exists to prevent.

`config.correlated_databases` invited a *database* name where a **connection**
name was required. A real application was configured with one. Every trigger
still fired and every row was still written, all with a NULL actor and NULL
`request_id` — indistinguishable from a console session. It is now
`config.correlated_connections`, with no deprecated alias and a boot check that
refuses to start on a value matching nothing.

And the library assumed the `public` schema, in both directions. A trigger
function pinned to `public` filed every schema's rows in one table while the
writes succeeded; a provisioning check asking about `public.audit_changes_2026_08`
reported the work done to a caller provisioning somewhere else; and the catalog
queries that filtered on `relname` alone let one schema's trigger vouch for
another schema's table, so `rake audit_log:coverage` passed while a table went
unaudited. Everything now operates on `current_schema()`. **Nothing changes for a
single-schema application** — which is nearly all of them — because
`current_schema()` is `public`. No configuration was added and no tenancy library
is named: this is the removal of an assumption, not a new feature. DESIGN §14 is
rewritten accordingly.

Requires Ruby >= 3.3, Rails ~> 8.0, PostgreSQL >= 16.

### Changed — breaking

- **`config.correlated_databases` is now `config.correlated_connections`, with no
  deprecated alias.** An initializer that sets the old name raises
  `NoMethodError` at boot, which is deliberate: the value was being misread, and
  a silent alias would preserve the misreading.

  It takes **connection** names as they appear in `database.yml` (`primary`,
  `queue`) and is compared against `connection.pool.db_config.name`. The old name
  invited a *database* name, and a real app was configured with one. Nothing
  raised — every trigger still fired and every row was still written, all with a
  NULL actor and NULL `request_id`, indistinguishable from a console session. An
  app can run that way for months and find out when an auditor asks who did
  something. That is the under-report this library exists to prevent, reached
  through its own configuration.

  **Most apps should delete the line rather than rename it.** The default
  `%w[primary]` is correct for any single-database app, *including one whose
  `database.yml` has no `primary:` key* — Rails names a flat config `primary`.
  Set it only for a multi-database app that audits tables outside the primary
  connection.

### Added

- **`spec/audit_log/schema_isolation_spec.rb`** installs the library into a bare
  second schema and asserts where the rows land, including that a table in
  another schema keeps its own audit trail and that shadowing `audit_changes`
  into an earlier `search_path` entry cannot redirect a write. Seven of its
  eight examples fail against the previous behaviour. It uses no tenancy gem —
  a second schema and a `search_path` is all this library is entitled to know
  about.
- **`AuditLog::Schema.function_sql` and `.qualified_function_name`** are public,
  so a host app can see what it is about to install.
- **A boot check.** `Configuration#verify_correlated_connections!` raises when
  the configured names match no connection at all, and warns on a partial miss —
  `%w[primary replica]` is legitimate in an app whose test environment has no
  replica, so raising there would refuse to boot a correct configuration. The
  error names both what was configured and what is available.
- **`correlation_spec` pins the assumption the default rests on**: that Rails
  normalizes a flat, single-database `database.yml` to the name `primary`. If
  that ever changed, every adopter on a flat config would silently stop
  correlating, and nothing else would say so.

### Fixed

- **The trigger function is installed into the current schema and names its
  destination in full**, rather than being `public.audit_row_change` pinned to
  `SET search_path = pg_catalog, public` and writing to an unqualified
  `audit_changes`. `attach_audit_trigger` now references the function
  unqualified, so `CREATE TRIGGER` binds permanently to the copy installed
  alongside it by the same migration run.

  **Nothing changes for a single-schema application** — `current_schema()` is
  `public`, one copy of the function is installed, and the emitted DDL is
  equivalent. In an application whose `search_path` is not `public` the old
  behaviour was wrong in the worst available way: `audit_tables.sql` creates its
  tables unqualified, so they followed `search_path` into the current schema
  while every row the triggers wrote went to `public`. The writes succeeded.
  Nothing reported anything.

- **`AuditLog::Partitions.exists?` no longer asks `to_regclass('public.' ||
  name)`.** Provisioning a second schema found `public`'s partition, reported
  the work already done, and created nothing — leaving a parent with no
  partitions at all, which then failed on its first audited write with `no
  partition of relation "audit_changes" found for row`.

- **`Partitions.attached?`, the three partition inventory queries, both
  `AuditLog::Coverage` queries and three `audit_log:benchmark` queries are
  scoped to `current_schema()`.** They filtered on `relname` alone, so they saw
  every schema's objects at once. For `Coverage` that is the whole ballgame: one
  schema's trigger vouched for another schema's table and the forcing function
  passed while a table went unaudited.

  This adds no configuration and names no tenancy library. It is the removal of
  an assumption, not the addition of a feature — see DESIGN §14, which was
  rewritten and whose previous advice recommended the shared-function
  arrangement this replaces.

- **The Rails 8.0 CI gap is closed**, and it was a real gap rather than a
  formality. `rails: ["8.0", "latest"]` joins the Ruby and PostgreSQL floor legs
  on the same argument: a floor nothing runs against is a guess. It found one
  breakage on the first run — `spec/dummy` pinned `config.load_defaults 8.1`,
  which raises `Unknown version "8.1"` on Rails 8.0 before an example loads — and
  a second that only CI could see: the dummy app's migrations were declared
  `ActiveRecord::Migration[8.1]`, which Rails 8.0 rejects, invisible locally
  because an already-migrated database never loads the file. The library itself
  needed no change; the install and trigger generators already emit the adopter's
  own `ActiveRecord::Migration.current_version`.
- **`AuditLog.notify`'s fallback for the absent `Rails.event` is now exercised.**
  Rails 8.0 has no event reporter, so the floor takes a different branch than the
  development version — and it was the branch nothing ran. `event_transport_spec`
  asserts which branch each Rails takes, in both directions, so the leg proves
  the fallback works rather than that nothing raised.

`latest` is unpinned on purpose: it is the newest Rails the gemspec admits, so
8.2 is tested the day it ships. Six legs, not eight — Rails 8.0 runs at every
floor at once (Ruby 3.3 / PG 16) and on the development pair (4.0.6 / PG 18).

## 0.2.0 — 2026-08-30

**`pagy` is no longer a dependency.** `AuditLog::Pagination` is unchanged in shape
— `include` it, call `paginate(scope, limit:)`, read `records` and `next` — and is
now this library's own keyset pager rather than a wrapper over `Pagy::Keyset`.

The reason is the host application, not Pagy. Bundler resolves one `pagy` per app;
keyset paging exists in Pagy from 9.0 and the `jsonify_keyset_attributes:` hook
that `FULL_PRECISION` cannot work without only from 9.3, and Pagy 43 removed that
hook again. The only honest dependency was therefore `~> 9.3` — two releases — and
it propagated into every adopter's own pagination: an app on Pagy 5, or on current
Pagy, could not install 0.1.0 at all. Nothing here ever used Pagy's frontend.
DESIGN §11.0 carries the amendment.

### Changed

- **`pagy` removed from the gemspec.** The one runtime dependency besides `rails`
  is now `csv`. Paginate the rest of your app with anything, or nothing.
- **`@pagy` renamed to `@page`** in the engine's controllers and views, in the
  `audit_log:views:activity` templates, and in the README. If you generated the
  activity views under 0.1.0 they are yours and keep working — the rename is not
  applied to files you already own, and `@pagy` is still a valid ivar name.
- **A non-column ordering now raises `Pagination::InvalidCursor`** and falls back
  to the newest page, where it previously raised `NoMethodError` on an
  `Arel::Nodes::SqlLiteral` and took the screen down.

### Unchanged

Rule 2 itself, every screen, the cursor format, and all four properties DESIGN
§11.0 lists — including the microsecond cursor, which `pagination_spec` still
pins with six rows inside one millisecond.

## 0.1.0 — 2026-08-30

First release. There is deliberately no history before this entry: the library
was developed as `lib/audit_log/` inside the reference application and extracted
into a gem, and none of that predates a version anybody could have installed.

- **Layer 1** — PostgreSQL `AFTER ... FOR EACH ROW` triggers write a jsonb
  field-level diff of every INSERT, UPDATE and DELETE to `audit_changes`.
  `update_all`, `delete_all`, `insert_all`, `upsert_all`, a database cascade, raw
  SQL, a rake task and a console session are all captured. Nothing goes in a
  model class.
- **Layer 2** — `AuditLog.notify` emits a registered action; one durable
  subscriber writes a human-readable row to `audit_events`. Joined to layer 1 by
  a UUIDv7 `request_id`, one per unit of work.
- **Actor propagation** through web requests, background jobs (with the
  originating request as `caused_by_request_id`), and the console.
- **`AuditLog::Coverage`** and a shared RSpec example, so a table that is neither
  audited nor exempted *with a written reason* fails the build.
- **An auditor UI at `/audit`**, served by the engine: actor activity, record
  history in three tabs, action reports, out-of-band review, request drill-down,
  CSV export.
- **`AuditLog::Timeline`** — a published, host-facing contract of value objects
  for rendering one record's history in your own app, plus
  `rails generate audit_log:views:activity` to install starter views for it.
- **`AuditLog::Pagination`** — keyset paging with a microsecond cursor, host-facing.
- **Storage lifecycle** — monthly range partitions, daily rotation and freezing,
  default-partition drain, yearly rollup, retention that detaches and never
  drops, and verified gzipped-CSV export before disposal.
- **`AuditLog::Redaction`** — GDPR erasure that removes values and keeps
  structure, and narrates itself in the same transaction.
- **Generators** — `audit_log:install`, `audit_log:trigger`,
  `audit_log:views:activity`.
- **Zero application constants.** Every coupling point is a lambda or string on
  `AuditLog.config`.

Requires Ruby >= 3.3, Rails ~> 8.0, PostgreSQL >= 16. CI runs the suite on Ruby
3.3 and 4.0.6 against PostgreSQL 16 and 18.

### Known gaps

- **No Rails 8.0 CI leg.** The gemspec claims `~> 8.0` but CI tests 8.1 only, so
  `AuditLog.notify`'s documented fallback for the absence of `Rails.event` is
  untested at the floor.

---

[`DESIGN.md`](DESIGN.md) is the record of *why* anything here is shaped the way
it is, and is where design amendments are written down. This file records what
changed between released versions; for anything finer, read the git history.
