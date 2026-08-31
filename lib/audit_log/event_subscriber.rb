# frozen_string_literal: true

module AuditLog
  # The one durable subscriber. Turns a Rails.event notification into an
  # audit_events row.
  #
  # `create!` joins the ambient transaction on purpose, so a rollback discards
  # the audit event along with the change it described. That is also the reason
  # this is not deferred to after_commit or to a background job.
  class EventSubscriber
    def emit(event)
      name    = event[:name].to_s
      entry   = AuditLog::Registry[name] or return
      payload = (event[:payload] || {}).symbolize_keys

      # The registry's payload contract, checked at the ONE point every call path
      # crosses -- AuditLog.notify, AuditLog.audited, and a bare Rails.event.notify
      # all arrive here. Checking it in `audited` instead would make the guard a
      # reason to prefer one call site over another, which is backwards.
      #
      # Raising is the same position the engine takes with raise_on_error: this
      # runs inside the caller's transaction, so a broken narrative rolls the
      # change back rather than committing beside a sentence with a hole in it.
      #
      # key? and not the value: metadata is stored `.compact`ed, so a deliberate
      # `reason: nil` and a forgotten `reason:` produce an identical row, and this
      # is the only place that distinction can still survive.
      #
      # EXTRA keys are not an error and are stored as-is. Payloads legitimately
      # grow, and a call-site typo is already caught by the missing half.
      if entry.requires
        missing = entry.requires.reject { |key| payload.key?(key) }
        if missing.any?
          raise AuditLog::MissingPayloadKeys,
                "#{name} omitted #{missing.map(&:inspect).join(", ")}. Its registry entry " \
                "declares requires: #{entry.requires.inspect}, and the payload carried " \
                "#{payload.keys.map(&:inspect).join(", ").presence || "no keys"}. Either the " \
                "emitting call site is missing the key (or misspelled it), or the entry in " \
                "config/initializers/audit_log.rb declares one it no longer needs."
        end
      end

      subject_type, subject_id = entry.subject.call(payload)

      # An uncorrelated entry point (bare `rails runner`, a migration) still has
      # to produce a NOT NULL request_id. Assign it back onto Current rather than
      # using a throwaway, so any transaction later in this same unit of work is
      # stamped with the id the event already carries.
      AuditLog::Current.request_id ||= AuditLog::Context.new_request_id

      AuditLog::Event.create!(
        request_id:   AuditLog::Current.request_id,
        action:       name,
        actor_type:   AuditLog::Current.actor_type,
        actor_id:     AuditLog::Current.actor_id,
        actor_label:  AuditLog::Current.actor_label,
        subject_type: subject_type,
        subject_id:   subject_id,
        source:       AuditLog::Current.source || "system",
        ip:           AuditLog::Current.ip,
        user_agent:   AuditLog::Current.user_agent,
        # Rendered NOW and stored, never re-rendered at display time: a copy edit
        # to an I18n key must not alter the historical record (R6).
        summary:      entry.summary.call(payload).to_s,
        # A first-class column, not a metadata key: metadata belongs to the
        # ACTION's payload, and merging framework plumbing into it means a
        # registered action carrying its own :caused_by_request_id silently wins.
        caused_by_request_id: AuditLog::Current.caused_by_request_id,
        metadata:     payload.compact
      )
    end
  end
end
