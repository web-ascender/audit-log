# Changelog

## Unreleased

### Extracted from the reference application

Everything below this heading predates the gem: `audit_log` began as
`lib/audit_log/` inside the `audit-log-demo` Rails application, and that history
is preserved here via `git subtree split`. The demo app remains the reference
implementation and now consumes this gem.

- Conventional engine layout: `app/`, `config/` and `db/` at the gem root, and
  `Engine.find_root` deleted — it existed only to stop the root-walk resolving to
  the host application while the library lived inside one.
- `lib/audit_log.rb` autoloads by feature name rather than absolute path, now
  that the gemspec puts `lib/` on the load path.
- Added `rails generate audit_log:install` and `audit_log:trigger`.
- Proprietary and internal: `LICENSE.txt` replaces the MIT placeholder, the
  gemspec declares `LicenseRef-Proprietary`, and `allowed_push_host` is set to a
  non-host so `gem push` fails locally rather than publishing to rubygems.org.
