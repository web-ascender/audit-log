# frozen_string_literal: true

module AuditLog
  # The allowlist of actions the system considers auditable, and the home of the
  # human sentence for each.
  #
  # Auditors like a finite, reviewable list of what counts as an auditable
  # action, and an allowlist gives them one. It is also what keeps analytics
  # events out of the audit tables: an event with no registry entry reaches the
  # observability subscriber and is ignored by AuditLog::EventSubscriber.
  class Registry
    Entry = Struct.new(:action, :subject, :summary, :description, keyword_init: true)

    class << self
      def register(action, subject: nil, summary:, description: nil)
        entries[action.to_s] = Entry.new(
          action: action.to_s,
          subject: subject || ->(_payload) { [nil, nil] },
          summary: summary,
          description: description
        )
      end

      def [](action)
        entries[action.to_s]
      end

      def keys
        entries.keys.sort
      end

      def entries
        @entries ||= {}
      end

      def clear!
        @entries = {}
      end
    end
  end
end
