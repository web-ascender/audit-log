# Changelog

## Unreleased

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
