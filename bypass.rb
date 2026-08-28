# frozen_string_literal: true

module AuditLog
  # The one explicit escape hatch from layer 1, for bulk loads where writing an
  # audit row per record is genuinely not wanted.
  #
  #   AuditLog.without_logging(reason: "Nightly ERP sync", by: ErpSyncJob) do
  #     Product.upsert_all(rows)
  #   end
  #
  # THE BYPASS LOGS ITSELF. Before disabling anything it writes an audit_events
  # row naming the reason, the actor, and the caller. An un-narrated gap in the
  # log is an audit finding; a narrated one is a control.
  module Bypass
    class << self
      def call(reason:, actor: nil, by: nil)
        raise ArgumentError, "a reason is required" if reason.blank?

        authorize!(by)

        AuditLog::Current.request_id ||= AuditLog::Context.new_request_id
        AuditLog::Current.actor = actor if actor

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result  = nil

        ActiveRecord::Base.transaction do
          # Written BEFORE the bypass is enabled, and inside the same transaction,
          # so a rollback discards the narration along with the work it described.
          AuditLog.notify("audit.bypass",
            reason: reason,
            by: by.to_s.presence,
            actor_label: AuditLog::Current.actor_label)

          toggle(true)
          begin
            result = yield
          ensure
            toggle(false)
          end
        end

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        AuditLog.notify("audit.bypass_completed", reason: reason, duration_ms: (elapsed * 1000).round)

        result
      end

      private

      # An intent declaration, not a security boundary -- anything that can call
      # this can also edit the allowlist. Its value is that turning the bypass on
      # for a new caller shows up as a diff in one reviewable file.
      def authorize!(by)
        return if AuditLog.config.bypass_allowlist.map(&:to_s).include?(by.to_s)

        raise AuditLog::BypassNotPermitted,
          "#{by.inspect} is not in AuditLog.config.bypass_allowlist"
      end

      def toggle(on)
        ActiveRecord::Base.connection.exec_query(
          "SELECT set_config('audit.bypass', $1, true)", "AUDIT BYPASS", [on ? "on" : "off"]
        )
      end
    end
  end
end
