# frozen_string_literal: true

module AuditLog
  module AuditHelper
    OPERATION_CLASS = { "I" => "op-insert", "U" => "op-update", "D" => "op-delete" }.freeze

    def audit_operation_badge(change)
      tag.span(change.operation_name, class: "badge #{OPERATION_CLASS[change.operation]}")
    end

    def audit_source_badge(source)
      tag.span(source, class: "badge source-#{source}")
    end

    def audit_time(time)
      return "" if time.blank?
      tag.time(l(time, format: :short), datetime: time.iso8601, title: time.iso8601)
    end

    # A diff value is [old, new]. The three shapes carry different meanings and
    # must not be rendered identically:
    #
    #   ["pending", "approved"]  changed        Pending -> Approved
    #   [nil, "approved"]        set on insert  (not set) -> Approved
    #   ["approved", nil]        CLEARED        Approved -> (cleared)
    def audit_value(value, cleared: false)
      if value.nil?
        tag.span(cleared ? "(cleared)" : "(not set)", class: "nil-value")
      elsif value.is_a?(Hash) || value.is_a?(Array)
        tag.code(truncate(value.to_json, length: 120))
      elsif value.to_s.empty?
        tag.span("(empty)", class: "nil-value")
      else
        tag.span(truncate(value.to_s, length: 160))
      end
    end

    def audit_field_row(column, old_value, new_value)
      tag.tr do
        tag.td(column, class: "field-name") +
          tag.td(audit_value(old_value), class: "old") +
          tag.td("→", class: "arrow") +
          tag.td(audit_value(new_value, cleared: new_value.nil? && !old_value.nil?), class: "new")
      end
    end

    # A payload value, rendered in full.
    #
    # Deliberately NOT audit_value: that one truncates, which is right for a diff
    # cell sitting in a wide table and wrong here. metadata is the structured
    # evidence behind the summary sentence -- the exact total_cents, the whole
    # tracking number -- and an ellipsis in it is an audit screen quietly
    # under-reporting. Payloads are a handful of scalars; CSS wraps the long ones.
    def audit_metadata_value(value)
      case value
      when nil          then tag.span("(not set)", class: "nil-value")
      when Hash, Array  then tag.code(value.to_json)
      when true, false  then tag.code(value.to_s)
      else
        value.to_s.empty? ? tag.span("(empty)", class: "nil-value") : value.to_s
      end
    end

    def audit_changed_columns(change)
      safe_join(change.changed_columns.sort.map { |c| tag.code(c, class: "col-chip") }, " ")
    end

    # An actor cell built from a GROUP BY rollup, which has a tuple rather than a
    # record. Renders through ActorLabel so it reads identically to
    # Event#actor_display / Change#actor_display, and -- the part that matters --
    # only LINKS when there is an actor to link to. A NULL actor has no activity
    # page: `actor_path(nil)` raises UrlGenerationError, which took down the whole
    # screen the first time an actorless action (a redaction run from rake) was
    # rolled up on it.
    def audit_actor_cell(actor_type, actor_id, actor_label = nil, **link_params)
      label = AuditLog::ActorLabel.display(actor_type, actor_id, actor_label)

      unless AuditLog::ActorLabel.linkable?(actor_type, actor_id)
        return tag.span(label, class: "muted", title: "No actor recorded — see CLAUDE.md on NULL actors")
      end

      link_to label, actor_path(actor_id, audit_range_params.merge(actor_type: actor_type, **link_params))
    end

    def audit_range_params
      date_range.to_param
    end

    # The TRAILING group, never a prefix.
    #
    # request_id is a UUIDv7, whose first 48 bits are the millisecond it was
    # minted. Taking `first(8)` keeps 32 of those 48 bits and drops the low 16, so
    # its resolution is 2^16 ms -- roughly 65 SECONDS. Every action in the same
    # minute renders as the same string, which is exactly the collision a short id
    # exists to prevent. Prefix-truncating is a habit from v4 ids, where the
    # leading bits are random; in v7 they are deliberately not.
    #
    # The last group is 48 bits of rand_b, so it disambiguates. It also loses
    # nothing: the timestamp half is redundant with the "When" column sitting next
    # to it on every screen that renders this.
    def audit_short_id(request_id)
      request_id.to_s.split("-").last.presence || request_id.to_s
    end

    # Keyset paging controls: "older", and a way back to the top. No page
    # numbers and no total, on purpose -- see AuditLog::Pagination and §11.0
    # Rule 2. `pagy.next` is nil exactly when this is the last page, which is
    # how the screen can say "end of results" honestly instead of leaving the
    # reader to guess whether a cap was hit.
    def audit_pagination(pagy, count)
      return if pagy.nil?

      tag.nav(class: "pagination") do
        safe_join([
          tag.span("#{count} row#{"s" unless count == 1} on this page", class: "small"),
          (link_to("Back to newest", url_for(page: nil), class: "button") if params[:page].present?),
          if pagy.next
            link_to "Older →", url_for(page: pagy.next), class: "button"
          else
            tag.span("End of results.", class: "small muted")
          end
        ].compact, " ")
      end
    end

    # Same URL, same filters, same date range -- only the format differs. That is
    # the point: the export is provably the screen the auditor is looking at, not
    # a second query that might disagree with it.
    #
    # `?format=csv` rather than a `.csv` path extension, because action ids
    # contain dots. `/audit/actions/order.submitted.csv` is recognised as
    # `id: "order.submitted.csv"` with NO format -- the greedy `[^/]+` constraint
    # swallows the extension -- so the path form silently serves HTML for an
    # action that does not exist. Rails reads :format out of the query string just
    # as happily, and it behaves the same on every screen.
    def audit_csv_link
      query = request.query_parameters.merge(format: "csv").to_query

      link_to "Export CSV", "#{request.path}?#{query}", class: "button csv"
    end

    def audit_request_link(request_id)
      return tag.span("out of band", class: "badge out-of-band") if request_id.blank?

      link_to audit_short_id(request_id), request_path(request_id),
              class: "mono", title: request_id
    end
  end
end
