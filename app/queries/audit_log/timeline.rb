# frozen_string_literal: true

module AuditLog
  # "Show me everything that happened to this order, the way a person would tell
  # it." The host-app-facing surface: a paginated list of UNITS OF WORK, each one
  # carrying its narrative, this record's own field changes, and the other
  # records the same action touched.
  #
  # WHY THIS EXISTS AS OBJECTS RATHER THAN RELATIONS. The auditor UI encodes
  # rules that are invisible from outside the gem -- that a diff value's three
  # nil shapes mean different things, that a nil actor renders "System" but is
  # never stored that way, that a redacted payload and an absent one are the same
  # empty jsonb and only the marker tells them apart, that an association label
  # annotates a recorded id and must never replace it. Ship the relations alone
  # and every host app re-derives those, and some get them wrong on a screen that
  # looks fine. The value objects make the rules a method call.
  #
  # THE SPINE IS audit_changes ("Spine A"). The record's own change rows, keyset
  # paged on (record_type, record_id, occurred_at DESC) -- the same proven scan
  # Screen A uses -- and then grouped into units of work.
  #
  # What that buys: completeness for every WRITE. Nothing that modified this
  # record can be missing from the timeline, whatever path it took, because layer
  # 1 captured it regardless of the registry.
  #
  # What it costs, and this is disclosed rather than hidden: an event that named
  # this record as its subject but wrote NO change row to it does not appear.
  # `order.emailed`, where the write lands in `deliveries`, is the shape of that.
  # `AuditLog::RecordTimeline#events` still lists it, and the Actions tab still
  # shows it. Closing the gap means unioning the two tables into the spine, which
  # changes the keyset -- see DESIGN §11.2b.
  class Timeline
    attr_reader :record_type, :record_id, :labels

    # `for` takes the host's own record, which is the ergonomic entry point and
    # the only place this library ever touches an application object -- it reads
    # `.class.name` and `.id` off it and keeps neither.
    def self.for(record, **kwargs)
      new(record_type: record.class.name, record_id: record.id, **kwargs)
    end

    def initialize(record_type:, record_id:, labels: nil)
      @record_type = record_type
      @record_id   = record_id
      @labels      = labels || AuditLog::LabelResolver.new
    end

    # The spine, as an ORDERED, UNLIMITED relation. The caller paginates it and
    # then hands the page back to #entries. Two calls rather than one because a
    # limit applied below the controller is invisible to the screen rendering it
    # -- DESIGN §11.0 Rule 2, and the reason the old 200-row cap was a silent
    # truncation.
    def changes
      AuditLog::Change.for_record(record_type, record_id).newest_first
    end

    # A page of change rows -> [Entry], newest first.
    #
    # Three queries for the whole page regardless of its size: the changes of
    # every request on the page, the events of every request on the page, and one
    # label warm. Both hydration queries are date-bounded off the page's own rows
    # (Record.grouped_by_request), so they prune partitions.
    def entries(page)
      page = Array(page)
      return [] if page.empty?

      related = AuditLog::Change.grouped_by_request(page)
      events  = AuditLog::Event.grouped_by_request(page)
      labels.warm(related.values.flatten + page)

      correlated, out_of_band = page.partition { |change| change.request_id.present? }

      entries = build_correlated(correlated, related, events, page.first.occurred_at)
      entries += out_of_band.map { |change| build(change.request_id, [change], [], nil) }
      entries.sort_by { |entry| [-entry.occurred_at.to_f, entry.request_id.to_s] }
    end

    private

    # One entry per request_id, in the order the page presented them.
    #
    # THE PAGE-BOUNDARY RULE. An entry is hydrated with EVERY change row of its
    # unit of work, including rows that fell past the end of the page -- that is
    # what keeps a unit of work whole instead of splitting it in half at a cursor.
    # The cost is that the next page, which starts at one of those older rows,
    # would render the same entry a second time.
    #
    # So an entry whose newest row for this record is newer than the page's own
    # newest row was necessarily shown in full on an earlier page, and is dropped
    # here. The check is local and stateless -- no cursor bookkeeping, nothing to
    # keep in sync -- and it can only ever drop a DUPLICATE: on the first page
    # nothing is newer than the head, and for the ordinary one-row-per-request
    # entry the row IS the max. Pinned by timeline_spec.
    def build_correlated(page_rows, related, events, page_head)
      seen = {}

      page_rows.each do |change|
        next if seen.key?(change.request_id)

        mine = mine_from(related, change)
        next if page_head && mine.map(&:occurred_at).max > page_head

        seen[change.request_id] = build(change.request_id, mine,
                                        events[change.request_id] || [],
                                        related[change.request_id])
      end

      seen.values
    end

    # This record's own rows in the unit of work. Falls back to the page row
    # itself if hydration returned nothing for the id -- a row older than the
    # bounded window would otherwise vanish from its own timeline, which is the
    # one failure this library never accepts.
    def mine_from(related, change)
      rows = (related[change.request_id] || []).select do |row|
        row.record_type == change.record_type && row.record_id == change.record_id
      end
      rows.presence || [change]
    end

    def build(request_id, mine, events, all_changes)
      entry = Entry.new(
        record_type: record_type, record_id: record_id,
        request_id: request_id,
        occurred_at: mine.map(&:occurred_at).max,
        events: events, changes: mine.sort_by(&:occurred_at), labels: labels
      )
      entry.also_touched = touched(all_changes)
      entry
    end

    # The OTHER records the unit of work wrote, one per (type, id) rather than
    # one per change row: a save that writes the same row twice is still one
    # record, and an entry claiming otherwise inflates what happened.
    def touched(all_changes)
      Array(all_changes)
        .reject { |c| c.record_type == record_type && c.record_id.to_s == record_id.to_s }
        .group_by { |c| [c.record_type, c.record_id] }
        .map do |(type, id), rows|
          label = labels.for(type, id)
          TouchedRecord.new(
            type: type, id: id,
            operations: rows.map(&:operation).uniq,
            columns: rows.flat_map(&:changed_columns).uniq.sort,
            label: (label if label.is_a?(String)),
            label_failed: label == AuditLog::LabelResolver::FAILED
          )
        end
    end
  end
end
