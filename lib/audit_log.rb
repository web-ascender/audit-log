# frozen_string_literal: true

# AuditLog -- a two-layer, compliance-grade audit log for Rails 8.
#
#   Layer 1 (database)    PostgreSQL AFTER ROW triggers write a jsonb field-level
#                         diff to audit_changes for every INSERT/UPDATE/DELETE on
#                         an audited table. Nothing bypasses it: not update_all,
#                         not delete_all, not raw SQL, not a DB cascade.
#
#   Layer 2 (application) Domain code emits named events via Rails.event; one
#                         durable subscriber writes a human-readable row to
#                         audit_events.
#
#   The join is request_id: one user action -> one audit_events row -> N
#   audit_changes rows sharing a UUIDv7.
#
# Install with `rails generate audit_log:install`; see README.md.
module AuditLog
  # The gem root, so Schema can find db/sql and the generators can find their
  # templates without going through Rails. Deliberately not Engine.root: the DDL
  # is usable from a plain migration, and a constant here needs no engine booted.
  GEM_ROOT = File.expand_path("..", __dir__)

  # autoload, not require: nothing here is needed until it is used, and the
  # engine's own app/ tree is Zeitwerk's business rather than this file's.
  #
  # NOTE for anyone tracing a stale constant in development: these files are
  # loaded ONCE per process. Only the engine's app/** reloads. AuditLog.config
  # memoizes its instance besides, so a changed Configuration needs a restart.
  {
    ActorLabel:        "audit_log/actor_label",
    Archive:           "audit_log/archive",
    Bypass:            "audit_log/bypass",
    Configuration:     "audit_log/configuration",
    Console:           "audit_log/console",
    Context:           "audit_log/context",
    CsvExport:         "audit_log/csv_export",
    ControllerContext: "audit_log/controller_context",
    Current:           "audit_log/current",
    EventSubscriber:   "audit_log/event_subscriber",
    JobContext:        "audit_log/job_context",
    MigrationHelpers:  "audit_log/migration_helpers",
    Pagination:        "audit_log/pagination",
    Partitions:        "audit_log/partitions",
    RecordLabel:       "audit_log/record_label",
    Redaction:         "audit_log/redaction",
    Registry:          "audit_log/registry",
    Schema:            "audit_log/schema",
    TransactionStamp:  "audit_log/transaction_stamp",
    VERSION:           "audit_log/version"
  }.each { |const, file| autoload const, file }

  class Error < StandardError; end

  # Raised when AuditLog::Bypass is invoked from a class that is not allowlisted.
  class BypassNotPermitted < Error; end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # The one call domain code makes. Thin wrapper over Rails.event so that
    # application code never references the transport directly, and so the same
    # call site works on Rails 8.0 (where Rails.event does not exist) by
    # falling back to the subscriber directly.
    def notify(action, **payload)
      if defined?(Rails.event) && Rails.event
        Rails.event.notify(action, **payload)
      else
        EventSubscriber.new.emit(name: action.to_s, payload: payload)
      end
    end

    # Runs a block with auditing disabled for the enclosing transaction.
    # Logs itself first -- see Bypass and plan §10.
    def without_logging(reason:, by: nil, actor: nil, &block)
      Bypass.call(reason: reason, by: by, actor: actor, &block)
    end
  end
end

# engine.rb requires rails/engine itself, so this needs no `defined?` guard --
# and must not have one: guarding on ::Rails::Engine would make the engine load
# or not depending on Gemfile ORDER, which is not something a host app should
# have to think about.
require "audit_log/engine"
