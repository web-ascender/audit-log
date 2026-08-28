# frozen_string_literal: true

module AuditLog
  # A console session is the highest-scrutiny write path in the system: it
  # produces changes with request_id IS NULL, which the auditor UI surfaces
  # prominently. Narrating the session converts the scariest category of write
  # into an explained one, for the price of one prompt.
  module Console
    class << self
      def start!
        AuditLog::Current.source     = "console"
        AuditLog::Current.request_id = AuditLog::Context.new_request_id

        reason = prompt_for_reason
        AuditLog.notify("console.session_opened",
          reason: reason, user: ENV["USER"], pid: Process.pid)
      rescue => e
        # Never prevent a console from opening.
        warn "[audit_log] could not narrate console session: #{e.class}: #{e.message}"
      end

      private

      def prompt_for_reason
        return "development console" unless Rails.env.production?
        return "unattended console" unless $stdin.tty?

        print "Reason for this production console session: "
        $stdin.gets.to_s.strip.presence || "(none given)"
      end
    end
  end
end
