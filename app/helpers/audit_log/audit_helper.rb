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

    def audit_changed_columns(change)
      safe_join(change.changed_columns.sort.map { |c| tag.code(c, class: "col-chip") }, " ")
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

    def audit_request_link(request_id)
      return tag.span("out of band", class: "badge out-of-band") if request_id.blank?

      link_to audit_short_id(request_id), request_path(request_id),
              class: "mono", title: request_id
    end
  end
end
