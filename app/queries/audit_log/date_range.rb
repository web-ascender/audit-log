# frozen_string_literal: true

module AuditLog
  # Rule 1 of every audit screen: carry a bounded date range.
  #
  # Partition pruning is the entire performance story. An unbounded "all time"
  # filter scans every partition of the largest table in the database, so the UI
  # does not offer one -- it offers a default of the last 30 days and a hard cap
  # on how far back a single page may reach.
  class DateRange
    DEFAULT_DAYS = 30
    MAX_DAYS     = 366

    attr_reader :from, :to

    def self.from_params(params)
      new(from: params[:from], to: params[:to])
    end

    def initialize(from: nil, to: nil)
      @to   = parse(to)&.end_of_day   || Time.zone.now.end_of_day
      @from = parse(from)&.beginning_of_day || (@to - DEFAULT_DAYS.days).beginning_of_day
      @from = (@to - MAX_DAYS.days) if (@to - @from) > MAX_DAYS.days
    end

    # Date#all_day-style bounds built in Time.zone, so they become timestamptz
    # bounds that prune correctly -- the auditor's calendar day, not UTC's.
    #
    # DELIBERATELY NOT UTC, and the one place in the library that is not. A date
    # filter is a human's calendar day; storage boundaries are UTC (see
    # AuditLog::Partitions). The consequence is that an app-zone range crosses a
    # UTC month boundary and touches ONE extra partition -- a known +1, not a
    # bug, and not worth trading the correct auditor-facing semantic for. Do not
    # "fix" this by moving the partition boundaries into the app zone: a
    # DST-observing boundary overlaps or gaps twice a year.
    def to_range = from..to
    def days     = ((to - from) / 1.day).round
    def to_param = { from: from.to_date.iso8601, to: to.to_date.iso8601 }

    private

    def parse(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
