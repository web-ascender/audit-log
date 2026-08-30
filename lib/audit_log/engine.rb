# frozen_string_literal: true

# `rails` before `rails/engine`, and not only for tidiness: rails/engine pulls in
# rails/initializable, which uses ActiveSupport's delegate_missing_to. Requiring
# rails/engine on its own raises NoMethodError unless something else happened to
# load ActiveSupport's core extensions first -- which, in a host app, depends on
# Gemfile ORDER. Both requires are idempotent, so this costs nothing when Rails
# is already loaded and makes `require "audit_log"` work regardless.
require "rails"
require "rails/engine"

module AuditLog
  # A conventional mountable engine: app/, config/ and db/ sit at the gem root,
  # so Rails::Engine finds them itself and this class needs no find_root
  # override. (It had one while the library lived inside a host app's lib/, where
  # the default root-walk would have resolved to the HOST app's root and pulled
  # in its app/ directories. Extracting to a gem removed the reason for it.)
  class Engine < ::Rails::Engine
    isolate_namespace AuditLog

    # ---------------------------------------------------------------- layer 1
    # Stamp the correlation context onto every transaction on an audited
    # database, so the trigger can read it. Plan §6.1.
    initializer "audit_log.transaction_stamp" do
      ActiveSupport.on_load(:active_record_postgresqladapter) do
        prepend AuditLog::TransactionStamp
      end
    end

    initializer "audit_log.migration_helpers" do
      ActiveSupport.on_load(:active_record) do
        ActiveRecord::Migration.include AuditLog::MigrationHelpers
      end
    end

    # ---------------------------------------------------------------- layer 2
    # Register the durable subscriber. Guarded so this engine still boots on
    # Rails 8.0, where Rails.event does not exist; there AuditLog.notify writes
    # through to the subscriber directly.
    initializer "audit_log.event_subscriber" do
      config.after_initialize do
        next unless Rails.respond_to?(:event) && Rails.event

        Rails.event.subscribe(AuditLog::EventSubscriber.new)

        # ActiveSupport::EventReporter rescues subscriber exceptions and reports
        # them to the error reporter as `handled: true` -- verified in
        # activesupport 8.1.3.1, event_reporter.rb:393. For an ordinary
        # observability subscriber that is the right default. For THIS
        # subscriber it is not: a swallowed exception means the narrative row is
        # missing while the change rows it describes committed anyway, and
        # nothing anywhere says so. Raising instead rolls the whole action back,
        # which is the behavior R3 (atomicity) actually asks for.
        Rails.event.raise_on_error = true if AuditLog.config.raise_on_subscriber_error
      end
    end

    # ------------------------------------------------- correlated connections
    # Refuse to boot on a correlated_connections that names nothing real. The
    # decision itself lives in Configuration#verify_correlated_connections!,
    # which carries the reasoning and is what the specs exercise.
    #
    # after_initialize, because database.yml is fully loaded by then and the
    # host's own initializer has already had its say.
    initializer "audit_log.verify_correlated_connections" do
      config.after_initialize do
        known = ActiveRecord::Base.configurations
                                  .configs_for(env_name: Rails.env)
                                  .map { |c| c.name.to_s }

        AuditLog.config.verify_correlated_connections!(known)
      end
    end

    # ------------------------------------------------------------------- misc
    # Partition bounds are stored as timestamptz, and pg_dump renders timestamptz
    # in the CLIENT's zone. Without this, db/structure.sql records correct
    # UTC-midnight boundaries as rotating local offsets --
    # FROM ('2026-07-31 20:00:00-04') TO ('2026-08-31 20:00:00-04') -- which is
    # unambiguous to Postgres (the offset is explicit, so it reloads exactly) but
    # reads to a human reviewer as though the months are misaligned, and shifts
    # spuriously across DST. PGTZ makes the dump say '+00' and say it stably.
    #
    # Safe to set globally: the postgresql adapter issues its own
    # `SET time zone 'UTC'` on every connection when ActiveRecord.default_timezone
    # is :utc, so this changes no runtime behavior -- only what subprocesses
    # (pg_dump, psql) render. `||=` so a host app can still override it.
    initializer "audit_log.utc_dumps" do
      ENV["PGTZ"] ||= "UTC"
    end

    # `console` and `rake_tasks` are class-level DSL, not initializers: the block
    # passed to `initializer` is instance_exec'd on the engine instance, which
    # does not respond to either.
    console do
      AuditLog::Console.start!
    end

    # __dir__ is lexical, so it still names lib/audit_log/ when this block is
    # instance_exec'd on the engine later.
    rake_tasks do
      load File.expand_path("tasks/audit_log.rake", __dir__)
    end
  end
end
