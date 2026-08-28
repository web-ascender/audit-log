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
