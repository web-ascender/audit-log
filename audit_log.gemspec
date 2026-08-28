# frozen_string_literal: true

require_relative "lib/audit_log/version"

Gem::Specification.new do |spec|
  spec.name     = "audit_log"
  spec.version  = AuditLog::VERSION
  spec.authors  = ["Kevin Southworth"]
  spec.email    = ["kevin.southworth@webascender.com"]

  spec.summary  = "A two-layer, compliance-grade audit log for Rails 8 and PostgreSQL."
  spec.description = <<~TEXT
    Layer 1 is PostgreSQL AFTER ROW triggers writing a jsonb field-level diff to a
    partitioned audit_changes table -- so update_all, delete_all, insert_all, raw
    SQL, a database cascade, a rake task and a console session are all captured,
    none of which a callback-based audit gem can see. Layer 2 is a registry of
    named application events, each with a human-readable summary, written to
    audit_events by one durable subscriber. The two join on a UUIDv7 request_id,
    so one user action reads as one action however many rows it touched.

    Ships partition rotation and retention, a redaction path for erasure requests,
    CSV export, and a mountable auditor UI.
  TEXT

  spec.homepage = "https://github.com/kevinsouthworth/audit_log"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  # No homepage_uri: rubygems warns when it duplicates source_code_uri and shows
  # only one of them anyway.
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "app/**/*",
    "config/**/*",
    "db/**/*",
    "lib/**/*",
    "README.md",
    "DESIGN.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]

  spec.require_paths = ["lib"]

  # Rails 8.0 is the floor, not 8.1: layer 2 prefers Rails.event and falls back
  # to calling the subscriber directly where it does not exist.
  spec.add_dependency "rails", ">= 8.0"

  # Both are for the auditor UI only -- layers 1 and 2 reference neither, and an
  # app that mounts nothing pays for neither at runtime.
  #
  # Hard dependencies rather than optional ones because pagy is load-bearing for
  # CORRECTNESS here, not convenience: AuditLog::Pagination is keyset paging, and
  # offset paging on a newest-first view of an append-only table silently
  # duplicates rows across page boundaries after a single concurrent write. See
  # DESIGN.md §11.0 Rule 2. `csv` is a former default gem that Ruby 3.4
  # unbundled, so declaring it is housekeeping rather than a new dependency.
  spec.add_dependency "pagy", "~> 9.3"
  spec.add_dependency "csv", "~> 3.3"

  # PostgreSQL is not optional and not swappable. The whole of layer 1 is a
  # plpgsql trigger function writing jsonb into range-partitioned tables. Left
  # out of the dependency list only because the host app chooses its own pg
  # build -- see the force_ruby_platform note in the demo app's Gemfile.
end
