# Changelog

Notable changes to `audit_log`. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

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
