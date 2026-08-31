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
    Entry = Struct.new(:action, :subject, :summary, :description, :requires, keyword_init: true)

    class << self
      # `requires:` is the payload contract, and it is the third point that makes
      # the two halves of a registered action agree. The call site's keys and the
      # `p[...]` reads in the lambdas above are otherwise checked by nothing, and
      # a typo on EITHER side renders an empty gap in a stored sentence -- one
      # that cannot be repaired later, because summaries are frozen at emit time
      # (R6). Declared, a typo on either side fails against the declaration.
      #
      # It lists what the entry cannot RENDER without, not every key the lambdas
      # read. A lambda spelled `Array(p[:columns]).presence || "all values"` has
      # already decided that key is optional; requiring it contradicts the entry.
      #
      # Optional per entry. An entry with no `requires:` is unchecked, exactly as
      # before -- which is what keeps this from being a landmine: a raise in
      # production is only reachable where somebody deliberately wrote a
      # contract, and an app adopts it action by action the way this file itself
      # fills in. Deleting the line is the escape valve; there is deliberately no
      # config flag to soften the check, for the reason `retention_action` is gone.
      def register(action, subject: nil, summary:, description: nil, requires: nil)
        entries[action.to_s] = Entry.new(
          action: action.to_s,
          subject: subject || ->(_payload) { [nil, nil] },
          summary: summary,
          description: description,
          requires: requires && Array(requires).map(&:to_sym).freeze
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
