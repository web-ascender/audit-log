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

    def audit_request_link(request_id)
      return tag.span("out of band", class: "badge out-of-band") if request_id.blank?
      link_to request_id.first(8), request_path(request_id), class: "mono"
    end
  end
end
