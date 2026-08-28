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

    # Streams rather than buffering: an export of a busy month is not something
    # to build in memory and hand to send_data.
    #
    # Last-Modified is set because Rack::ETag digests the whole body to compute
    # an entity tag when it has no other validator -- which would buffer the very
    # thing this is streaming to avoid.
    def stream_csv(export, prefix)
      response.headers["Content-Type"]        = "text/csv; charset=utf-8"
      response.headers["Content-Disposition"] =
        ActionDispatch::Http::ContentDisposition.format(disposition: "attachment",
                                                        filename: export.filename(prefix))
      response.headers["Last-Modified"]       = Time.now.httpdate
      response.headers["X-Accel-Buffering"]   = "no"

      self.response_body = export.each
    end

    def date_range
      @date_range ||= AuditLog::DateRange.from_params(params)
    end
    helper_method :date_range
  end
end
