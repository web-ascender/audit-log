# frozen_string_literal: true

module AuditLog
  # Q4 -- "Everything that happened to invoices in department 5." The one auditor
  # question this library cannot pose on its own, because the facets belong to the
  # host application. DESIGN §23.
  #
  # The screen knows no host model. Which facets it offers, what they are called
  # and where their options come from are all `config.dimension_filters`, and with
  # that unset the screen says so rather than rendering an empty form -- the same
  # reason `config.record_url` defaults to nil instead of guessing a route.
  class DimensionsController < ApplicationController
    def index
      @filters  = AuditLog.config.dimension_filters
      @selected = selected_dimensions
      @timeline = dimension_timeline

      return stream_csv(AuditLog::CsvExport.for(csv_scope), "audit-dimensions") if
        request.format.csv?

      @page       = paginate(@timeline.activity_keys)
      @activities = @timeline.activities(@page.records)
    end

    private

    # ONLY THE KEYS THE HOST DECLARED, and the filtering is the point rather than
    # tidiness. `?d[whatever]=x` is a URL anybody can type, and a screen that
    # honours it renders a filter for a facet this application never declared and
    # can never match -- an empty result that looks like an answer. Same discipline
    # as checking VIEWABLE before constantize in the activity generator: a screen
    # over audit data does not take its vocabulary from the query string.
    #
    # Blank values are dropped by Record.normalize_dimensions, so an untouched
    # field in the form is not a filter on the empty string.
    def selected_dimensions
      submitted = params[:d]
      return {} unless submitted.respond_to?(:to_unsafe_h) || submitted.is_a?(Hash)

      submitted = submitted.to_unsafe_h if submitted.respond_to?(:to_unsafe_h)
      submitted.select { |key, _| @filters.key?(key.to_sym) }
    end

    # Shares ONE LabelResolver with the view, so the feed and anything else the
    # page renders resolve against one warmed cache rather than two. Same seeding
    # RecordsController does.
    def dimension_timeline
      @audit_labels ||= AuditLog::LabelResolver.new
      AuditLog::DimensionTimeline.new(
        dimensions: @selected, range: date_range.to_range, labels: @audit_labels
      )
    end

    # WHAT THE SCREEN EXPORTS IS NOT WHAT IT PAGES, and the asymmetry is the same
    # one the record timeline's export has: the page lists UNITS OF WORK, which are
    # a grouping this library derived and not something the database recorded, so
    # the evidence artifact ships the matching CHANGE ROWS. An export claiming to
    # be a list of units would be claiming more than the log holds.
    #
    # It is the changes leg alone. A unit that qualified only through its event
    # has no matching change row to ship, which the screen says in the note beside
    # the link rather than papering over.
    def csv_scope
      AuditLog::Change.where_dimensions(@selected)
                      .occurred_between(date_range.to_range)
    end
  end
end
