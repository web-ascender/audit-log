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

    # The one definition of how a STORED actor reads on a screen, in fallback
    # order: the snapshotted label, then the bare identifier, then "System".
    #
    # "System" is a display-time rendering and nothing else. A nil actor is
    # stored as NULL precisely so a scheduled job stays distinguishable from a
    # console session that forgot to identify itself; writing the word into the
    # column would erase that distinction permanently.
    #
    # It lives here, and not in the models, because the third caller is a GROUP
    # BY rollup that has tuples rather than records. That caller previously
    # re-spelled the chain, dropped the nil branch, and raised on the first
    # actorless action to reach the screen.
    def self.display(actor_type, actor_id, actor_label = nil)
      actor_label.presence || (actor_type ? "#{actor_type} ##{actor_id}" : "System")
    end

    # Is there an actor to link TO? A NULL actor has no activity page, because it
    # is not a someone.
    def self.linkable?(actor_type, actor_id)
      actor_type.present? && actor_id.present?
    end
  end
end
