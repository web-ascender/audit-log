# frozen_string_literal: true

module AuditLog
  # Q2, narrative half -- "What was DONE to Order #4821, in words?"
  #
  # AuditLog::RecordHistory answers the same question from audit_changes:
  # complete by construction, field-level, and the compliance-grade answer. This
  # answers it from audit_events, which is the layer a human reads. They are two
  # tabs on one screen for the same reason the actor screen has two, and the note
  # on each says which is which -- the narrative is readable but complete only
  # for actions someone remembered to register, and saying so costs less than
  # letting an auditor infer a completeness that is not there.
  #
  # THE SUBJECT INDEX IS THE POINT. Registry entries set `subject:` so an event
  # names the aggregate root it was about, and (subject_type, subject_id,
  # occurred_at DESC) has been in the schema since the first migration. Until
  # this object, AuditLog::Redaction was the only thing in the library that read
  # it -- the index existed, the scope existed, and no screen surfaced either.
  #
  # TWO POPULATIONS, DELIBERATELY NOT MERGED INTO ONE LIST:
  #
  #   events      -- the action NAMED this record as its subject. One index
  #                  scan, keyset-pageable, exact, and unbounded in range for
  #                  the same reason Screen A is (a single record has bounded
  #                  history).
  #   correlated  -- the action WROTE to this record but named something else,
  #                  or nothing, as its subject: a bulk price change, a
  #                  nested-attributes save whose subject is the parent, or an
  #                  action registered with no `subject:` lambda at all. Found
  #                  by matching request_id against this record's own change
  #                  rows, since that is the only link there is.
  #
  # Merging them would read better and would lie in two specific ways. It would
  # present an action that merely touched this record as equivalent to one that
  # was about it. And it would hide that the second population is CAPPED while
  # the first is not -- `correlated` scans a bounded number of the record's most
  # recent change rows and reports exactly how many, because a section that
  # quietly stops short is the failure this library is built to avoid.
  class RecordTimeline
    # What `correlated` scanned, and whether it ran out of budget before it ran
    # out of history. The view renders `scanned` and `truncated?` verbatim: the
    # claim "the 50 most recent changes to this record" is checkable in a way
    # that "recent activity" is not.
    Correlated = Struct.new(:events, :window, :scanned, :truncated, keyword_init: true) do
      def truncated? = truncated
      def any?       = events.any?
      def empty?     = events.empty?
    end

    attr_reader :record_type, :record_id, :range

    def initialize(record_type:, record_id:, range: nil)
      @record_type = record_type
      @record_id   = record_id
      @range       = range
    end

    # Returns an ORDERED, UNLIMITED relation: the caller paginates it. Same rule
    # as RecordHistory#changes -- a limit baked in below the controller is
    # invisible to the screen rendering it. DESIGN 11.0 Rule 2.
    #
    # Index: (subject_type, subject_id, occurred_at DESC).
    def events
      scope = AuditLog::Event.for_subject(record_type, record_id)
      scope = scope.occurred_between(range) if range
      scope.newest_first
    end

    # The change rows behind a page of events, for the expandable sub-section.
    # One bounded query for the whole page -- see Change.grouped_by_request.
    def changes_for(events)
      AuditLog::Change.grouped_by_request(events)
    end

    # Actions that touched this record without naming it.
    #
    # Two steps, because there is no third: audit_events has no per-record rows,
    # so the only evidence that an unsubjected action touched this record is a
    # change row sharing its request_id.
    #
    #   1. the record's own most recent change rows -> request ids + a real
    #      time window, both from a tight index scan on
    #      (record_type, record_id, occurred_at DESC).
    #   2. the events under those ids, minus the ones already listed above.
    #
    # THE CAP IS ON STEP 1 AND IS DISCLOSED. "The N most recent change rows for
    # this record" is a precise statement the screen can print; an unqualified
    # cap on the events would not be, because a record with a long history would
    # silently lose the older half of its correlations.
    def correlated(limit: nil)
      limit ||= AuditLog.config.page_size
      rows    = correlation_anchors(limit + 1)
      scanned = rows.first(limit)

      return Correlated.new(events: AuditLog::Event.none, window: nil, scanned: 0, truncated: false) if
        scanned.empty?

      times  = scanned.map(&:last)
      slack  = AuditLog.config.drill_down_slack
      window = (times.min - slack)..(times.max + slack)

      Correlated.new(
        events:    correlated_scope(scanned.map(&:first).uniq, window),
        window:    window,
        scanned:   scanned.size,
        truncated: rows.size > limit
      )
    end

    private

    # Out-of-band writes carry request_id IS NULL and correlate to nothing by
    # definition -- they are the reason the out-of-band screen exists. Including
    # them here would match every other uncorrelated row in the log.
    def correlation_anchors(limit)
      scope = AuditLog::Change.for_record(record_type, record_id).where.not(request_id: nil)
      scope = scope.occurred_between(range) if range
      scope.newest_first.limit(limit).pluck(:request_id, :occurred_at)
    end

    # `where.not(subject_type: t, subject_id: i)` is WRONG here and quietly so:
    # it compiles to NOT (subject_type = t AND subject_id = i), which evaluates
    # to NULL -- and therefore excludes the row -- whenever subject_type IS NULL.
    # An action registered with no `subject:` lambda is exactly that row, and it
    # is the single most important thing this section is here to surface. The
    # row-wise IS DISTINCT FROM is null-safe in both columns.
    def correlated_scope(request_ids, window)
      AuditLog::Event
        .where(request_id: request_ids)
        .where(occurred_at: window)
        .where("(subject_type, subject_id) IS DISTINCT FROM (?::text, ?::bigint)",
               record_type, record_id)
        .newest_first
    end
  end
end
