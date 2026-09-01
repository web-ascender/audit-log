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
    # The agent-facing entry point, and it has to be PACKAGED to do its job: an
    # agent working in a host app reaches these docs through `bundle info
    # audit_log --path` and nothing else. CLAUDE.md is deliberately absent from
    # this list for the mirror-image reason -- it is written for somebody
    # changing the gem, not using it. DESIGN §24.
    "llms.txt",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]

  spec.require_paths = ["lib"]

  # Rails 8.0 is the floor, not 8.1 (DESIGN §2.2): layer 2 prefers Rails.event and
  # falls back to calling the subscriber directly where it does not exist.
  #
  # BOUNDED at < 9.0, and not merely because rubygems advises against open-ended
  # dependencies. AuditLog::TransactionStamp prepends `raw_execute` -- a PRIVATE
  # ActiveRecord adapter method, and DESIGN §6.1 calls it the single private choke
  # point every write funnels through. Private APIs are exactly what a major
  # version is free to move. `>= 8.0` claimed Rails 9 and 10 work, which nobody
  # has verified and which that prepend makes implausible. Raising this ceiling is
  # a deliberate act that means re-verifying the prepend, not a formality.
  spec.add_dependency "rails", "~> 8.0"

  # For the CSV export only -- a former default gem that Ruby 3.4 unbundled, so
  # declaring it is housekeeping rather than a new dependency.
  spec.add_dependency "csv", "~> 3.3"

  # `pagy` is DELIBERATELY NOT A DEPENDENCY, and this gem must not acquire one.
  # AuditLog::Pagination is keyset paging and that is still non-negotiable
  # (DESIGN.md §11.0 Rule 2) -- it is now ~90 lines of this library's own, for a
  # reason that is about the host app rather than about Pagy.
  #
  # Bundler resolves exactly one pagy per app. Pagy grew keyset paging in 9.0 and
  # the `jsonify_keyset_attributes:` hook that Pagination::FULL_PRECISION cannot
  # work without in 9.3, then removed that hook again in the 43 rewrite. A
  # dependency this library could honestly declare was therefore `~> 9.3` --
  # two releases -- and it would have propagated straight into the host's own
  # pagination: an app on Pagy 5, or on current Pagy, could not have installed
  # this gem at all, and an app on 9.3 could never upgrade past it.
  #
  # An audit log has no business dictating how the rest of an app paginates. With
  # no dependency here the host runs whatever Pagy (or Kaminari, or nothing) it
  # likes, and these screens are unaffected by it.

  # PostgreSQL is not optional and not swappable. The whole of layer 1 is a
  # plpgsql trigger function writing jsonb into range-partitioned tables. Left
  # out of the dependency list only because the host app chooses its own pg
  # build -- see the force_ruby_platform note in the demo app's Gemfile.
end
