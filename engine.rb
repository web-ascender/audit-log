# frozen_string_literal: true

require "rails/engine"

module AuditLog
  # A mountable engine rooted at lib/audit_log/, so the whole library is one
  # directory. `find_root` is overridden because the default walks up from the
  # calling file looking for a `lib` directory, which from here would resolve to
  # the *host application's* root and pull in its app/ directories.
  class Engine < ::Rails::Engine
    ENGINE_ROOT = File.expand_path(__dir__)

    def self.find_root(_from)
      Pathname.new(ENGINE_ROOT)
    end

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

    rake_tasks do
      load File.expand_path("tasks/audit_log.rake", ENGINE_ROOT)
    end
  end
end
