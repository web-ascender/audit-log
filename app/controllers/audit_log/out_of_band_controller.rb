# frozen_string_literal: true

module AuditLog
  # Changes with request_id IS NULL: console sessions, migrations, rake tasks,
  # manual psql connections. This is a feature of the design, not a gap -- these
  # are the rows an auditor scrutinizes most, so they get their own screen.
  class OutOfBandController < ApplicationController
    def index
      scope = AuditLog::Change.out_of_band
                              .occurred_between(date_range.to_range).newest_first
      return stream_csv(AuditLog::CsvExport.for(scope), "audit-out-of-band") if request.format.csv?

      @pagy    = paginate(AuditLog::Change.out_of_band
                                          .occurred_between(date_range.to_range)
                                          .newest_first)
      @changes = @pagy.records
    end
  end
end
