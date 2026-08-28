# frozen_string_literal: true

module AuditLog
  # Include into ApplicationController. That is the whole web integration.
  module ControllerContext
    extend ActiveSupport::Concern

    included do
      before_action :set_audit_context
    end

    private

    def set_audit_context
      AuditLog::Current.request_id = AuditLog::Context.new_request_id
      AuditLog::Current.actor      = audit_actor
      AuditLog::Current.ip         = request.remote_ip
      AuditLog::Current.user_agent = request.user_agent
      AuditLog::Current.source     = audit_source
    end

    # Resolved through config so the library never names an authentication gem.
    # The default asks the controller for `current_user`, which Devise, the Rails
    # authentication generator, and every similar gem expose.
    def audit_actor
      AuditLog.config.actor_resolver.call(self)
    end

    def audit_source
      request.format.json? ? "api" : "web"
    end
  end
end
