# frozen_string_literal: true

# Copyright (c) 2026 Web Ascender. All rights reserved.
# CONFIDENTIAL AND PROPRIETARY PROPERTY. See LICENSE.txt.

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

  # 3.3, not 3.2, and DESIGN §2.1 has said so all along -- the floor exists
  # entirely for SecureRandom.uuid_v7, which landed in Ruby 3.3. UUIDv7 is what
  # gives the audit_changes(request_id) index insert locality on the
  # highest-volume table in the database, and Context.minted_at decodes the
  # embedded timestamp to bound the drill-down. On 3.2 every correlated write
  # raises NoMethodError.
  #
  # Ruby 3.3.0 EXACTLY is additionally unusable, and not because of anything here:
  # actionview 8.1.3.1 contains `yield(*, **)` inside a block, which 3.3.0's parser
  # rejects, while Rails still declares required_ruby_version >= 3.2.0. Any Rails
  # 8.1 app hits that, gem or no gem. Later 3.3 patches are fine.
  spec.required_ruby_version = ">= 3.3.0"
  spec.license = "LicenseRef-Proprietary"

  # PROPRIETARY AND INTERNAL. `LicenseRef-Proprietary` is SPDX's own convention
  # for a licence that is not on its list -- so this states "custom terms, read
  # LICENSE.txt" to a licence scanner, rather than either claiming an open-source
  # licence it is not or leaving the field empty, which rubygems warns about and
  # a reader cannot distinguish from an oversight.
  #
  # allowed_push_host is the load-bearing line. Set to a value that is not a real
  # host, it makes `gem push` FAIL rather than publishing to rubygems.org --
  # which is the failure mode LICENSE.txt exists to prevent, and the one that
  # cannot be undone once it happens. Distribute by path or by a private source,
  # never by push.
  spec.metadata["allowed_push_host"] = "none: internal use only, see LICENSE.txt"

  # A PRIVATE repo in the company GitHub organisation. Recorded because it is the
  # canonical source location, not because it is fetchable by anyone who reads
  # this metadata -- which is exactly why allowed_push_host above must stay set.
  spec.homepage = "https://github.com/web-ascender/audit-log"
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
