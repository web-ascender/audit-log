# frozen_string_literal: true

require_relative "boot"

# Only the frameworks the library actually touches. Notably absent: Solid Queue,
# Solid Cache, Solid Cable and any authentication gem -- if a spec passes here,
# the library genuinely does not need them.
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

# The gem under test. In a host app this comes from the Gemfile; here the gemspec
# path dependency has already put it on the load path.
require "audit_log"

module Dummy
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = File.expand_path("..", __dir__)

    # REQUIRED by the audit design, and required before the first migration
    # exists: schema.rb cannot represent partitioned tables, trigger functions or
    # triggers, all three of which layer 1 is built from. (DESIGN §4)
    config.active_record.schema_format = :sql

    # Deliberately NOT UTC, and deliberately not the same as the audit tables'
    # zone. Everything stored by either layer is UTC regardless -- occurred_at is
    # filled by a column DEFAULT of clock_timestamp(), so config.time_zone cannot
    # reach it. spec/audit_log/utc_storage_spec.rb is what proves that, and it
    # proves nothing if this is left at UTC.
    config.time_zone = "Central Time (US & Canada)"

    # The ActiveJob test adapter, not Solid Queue. The reference app runs Solid
    # Queue in test so that the adapter under test is the adapter in production;
    # this app is testing the LIBRARY, and the library's job integration is
    # adapter-agnostic (see JobContext). One less database, one less dependency.
    config.active_job.queue_adapter = :test

    config.eager_load = false
    config.consider_all_requests_local = true
    config.action_controller.allow_forgery_protection = false
    config.secret_key_base = "dummy-app-secret-key-base-for-specs-only"

    config.logger = ActiveSupport::Logger.new(File::NULL)
    config.log_level = :fatal
  end
end
