# frozen_string_literal: true

module AuditLog
  class Timeline
    # Who did it, as the audit row recorded them -- not as they are now.
    #
    # `label` is the SNAPSHOT the trigger and the subscriber both wrote from one
    # Current.actor_label string, so it stays correct after the user is renamed
    # or deleted. Nothing here re-reads the actor's current row, and a host app
    # that swaps `display` for a live lookup has let a rename retroactively
    # change what the log says happened. DESIGN §7.
    class Actor
      attr_reader :type, :id, :label

      def initialize(type:, id:, label:)
        @type  = type
        @id    = id
        @label = label
      end

      # NULL actor_type means no actor was recorded: a console session, a rake
      # task, a migration, a raw psql connection. The database stores NULL and
      # never the string "System" -- storing it would make a console session
      # indistinguishable from a genuine scheduled action -- so the fallback
      # lives here, at display time, and in exactly one place.
      def system? = type.nil?

      def display = AuditLog::ActorLabel.display(type, id, label)

      # False when there is nothing to link to. `actor_path(nil)` raising
      # UrlGenerationError is what took the action rollup screen down, and a host
      # app linking an actor cell will hit the same edge on the first actorless
      # entry -- a redaction run from rake, a nightly job.
      def linkable? = AuditLog::ActorLabel.linkable?(type, id)

      # Through the same seam as any other record, since an actor IS one.
      def url
        return nil unless linkable?

        AuditLog.config.record_url&.call(type, id)
      end

      def ==(other)
        other.is_a?(Actor) && other.type == type && other.id == id
      end
      alias_method :eql?, :==

      def hash = [Actor, type, id].hash

      def as_json(*)
        { "type" => type, "id" => id, "label" => label,
          "display" => display, "system" => system? }
      end
    end
  end
end
