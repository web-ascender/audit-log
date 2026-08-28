# frozen_string_literal: true

module AuditLog
  # Inherits from the HOST application's controller (configurable), which is how
  # these screens pick up its layout, authentication and helpers without the
  # library naming any of them.
  class ApplicationController < AuditLog.config.parent_controller.constantize
    include AuditLog::Pagination

    before_action { AuditLog.config.authorize.call(self) }

    helper AuditLog::AuditHelper

    private

    def date_range
      @date_range ||= AuditLog::DateRange.from_params(params)
    end
    helper_method :date_range
  end
end
