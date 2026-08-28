# frozen_string_literal: true

module AuditLog
  # "Show me everything that happened under this one correlation id."
  #
  # THE PROBLEM. Partition elimination is syntactic: the planner compares the
  # WHERE clause against each partition's declared range on occurred_at and skips
  # the ones that cannot match. `WHERE request_id = ?` mentions occurred_at not at
  # all, so nothing is eliminated and every partition is scanned. That is six
  # today and 84 at a 7-year retention horizon -- 84 index descents and 84
  # relation locks, on the hot path of the auditor UI, growing linearly with the
  # retention decision.
  #
  # THE FIX, in order of preference:
  #
  #   1. An EXACT anchor. Drilling down from an audit_events row means its
  #      occurred_at is already in hand -- see Event#changes_in_request. Free,
  #      exact, and assumes nothing about how the id was generated.
  #   2. The id ITSELF. request_id is a UUIDv7, whose first 48 bits are the
  #      milliseconds at which it was minted (Context.minted_at). The value
  #      already being filtered on supplies its own bound, with no extra column
  #      and no schema change.
  #   3. No bound at all, when the id is not a v7 UUID. Slow and correct beats
  #      fast and wrong.
  #
  # WHY THE WINDOW IS TIGHT AT ALL is worth stating, because it is not an
  # accident: a request_id's lifetime is one request or one job execution, since
  # jobs deliberately do NOT inherit the id of the request that enqueued them
  # (plan §6.4, and see caused_by_request_id). Had they inherited it, a job
  # running three days later would write rows under an id minted three days
  # earlier and the window would have to span the whole retention horizon -- which
  # is to say, no pruning. A decision made for timeline readability is what makes
  # this optimization possible.
  #
  # HONESTY ABOUT THE RISK. A too-narrow window shows FEWER rows than exist, and
  # quiet under-reporting is the worst failure an audit tool has. So the window is
  # generous (config.drill_down_slack, default 24h), `bounded?` and `window` are
  # exposed so the UI can say which query it ran, and `bounded: false` drops the
  # optimization entirely for an auditor who needs certainty over speed.
  class RequestDrillDown
    attr_reader :request_id, :slack, :anchor

    def initialize(request_id, anchor: nil, slack: nil, bounded: true)
      @request_id = request_id.to_s
      @slack      = slack || AuditLog.config.drill_down_slack
      @requested  = bounded
      @anchor     = anchor || AuditLog::Context.minted_at(@request_id)
      @exact      = !anchor.nil?
    end

    def events
      scope(AuditLog::Event).order(:occurred_at, :id)
    end

    def changes
      scope(AuditLog::Change).order(:occurred_at, :id)
    end

    # The units of work THIS one set in motion -- the jobs it enqueued. They carry
    # their own request_id and point back here through caused_by_request_id, an
    # indexed column since the "promote caused_by_request_id" migration; before
    # that this was `metadata ->> ...` and scanned every partition.
    #
    # Bounded by the same window as everything else. Half of it is provably empty
    # -- an effect cannot precede its cause -- so this could be tightened to a
    # one-sided forward range, but it would prune to the same partitions and the
    # forward reach is the half that matters (a job may retry for hours).
    def caused_events(limit: 50)
      rel = AuditLog::Event.where(caused_by_request_id: @request_id)
      rel = rel.where(occurred_at: window) if bounded?
      rel.order(:occurred_at, :id).limit(limit)
    end

    # False when the caller opted out, or when the id yielded no usable anchor.
    def bounded?
      @requested && !@anchor.nil?
    end

    def window
      return nil unless bounded?
      (@anchor - @slack)..(@anchor + @slack)
    end

    # :event      -- anchored on a row's own occurred_at. Exact.
    # :request_id -- decoded from the UUIDv7. Tight, but inferred.
    # :none       -- not a v7 id, or the caller opted out. Unbounded.
    def anchor_source
      return :none unless bounded?
      @exact ? :event : :request_id
    end

    # For the UI, so a narrowed query never looks like a complete one.
    def scope_description
      case anchor_source
      when :event      then "within #{describe_slack} of this action"
      when :request_id then "within #{describe_slack} of when this id was issued"
      else                  "across all retained history"
      end
    end

    def unbounded
      self.class.new(@request_id, anchor: nil, slack: @slack, bounded: false)
    end

    private

    def scope(model)
      rel = model.where(request_id: @request_id)
      bounded? ? rel.where(occurred_at: window) : rel
    end

    def describe_slack
      ActiveSupport::Duration.build(@slack.to_i).inspect
    end
  end
end
