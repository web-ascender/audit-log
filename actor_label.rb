# frozen_string_literal: true

module AuditLog
  # Renders the actor into the string that gets SNAPSHOTTED onto every audit row.
  #
  # Snapshot rather than join, on purpose (R6): if the auditor UI joined live to
  # `users` to render a name, then renaming or deleting a user would retroactively
  # change what the audit record says happened. Auditors read that as tampering.
  module ActorLabel
    MAX_LENGTH = 255

    # Returns nil for a nil actor -- see the note on AuditLog::Current#actor=.
    # The resolver is never called with nil, so host applications do not have to
    # handle that case.
    def self.for(actor)
      return nil if actor.nil?

      label = AuditLog.config.actor_label_resolver.call(actor)
      label.to_s.truncate(MAX_LENGTH).presence
    end
  end
end
