# Changelog

## Unreleased

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

Also: `spec/preview.rb` renders 15 screens rather than 13, and its bulk price
change now emits the `price.bulk_adjusted` it was always registered for — it is
the action with no `subject:`, so it is what gives the product preview something
to render in the correlated section.


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
