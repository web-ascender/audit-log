# frozen_string_literal: true

module AuditLog
  class DashboardController < ApplicationController
    def show
      range = date_range.to_range

      @event_count  = AuditLog::Event.occurred_between(range).count
      @change_count = AuditLog::Change.occurred_between(range).count
      @recent       = AuditLog::Event.occurred_between(range).newest_first.limit(15)

      @by_action = AuditLog::Event.occurred_between(range)
                                  .group(:action).order(count_all: :desc).count
      @by_type   = AuditLog::Change.occurred_between(range)
                                   .group(:record_type).order(count_all: :desc).count

      # The highest-scrutiny rows in the log get top billing, not a footnote.
      @out_of_band = AuditLog::Change.out_of_band
                                     .occurred_between(range)
                                     .newest_first.limit(10)
      @out_of_band_count = AuditLog::Change.out_of_band.occurred_between(range).count

      @uncovered = AuditLog::Reconciler.new(range: range).uncovered_requests.first(10)
      @partitions = AuditLog::Partitions.list
    end
  end
end
