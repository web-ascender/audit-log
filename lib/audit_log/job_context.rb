# frozen_string_literal: true

module AuditLog
  # Include into ApplicationJob. That is the whole background-job integration --
  # there is nothing per-job.
  #
  # The rule (plan §6.4):
  #
  #   inherited from the enqueuing context   generated fresh per execution
  #   ------------------------------------   -----------------------------
  #   actor_type, actor_id, actor_label      request_id
  #   ...recorded as caused_by_request_id    source = "job" | "system"
  #
  # Inherit the actor because the job acts on that person's behalf: if Jane
  # clicks Submit and a job finishes the work, her activity screen must show it.
  #
  # Do NOT inherit the request_id, for three reasons that all bite in production:
  #
  #   1. A job running three days later would write change rows whose request_id
  #      points at an event row in a partition three days back, so the drill-down
  #      join spans the whole retention window instead of one page's date range.
  #   2. A bulk job writing 500k rows under a user's request id makes that one
  #      action in her timeline expand to half a million children -- the
  #      paper_trail readability problem returning by the back door.
  #   3. Retries. Each attempt is a distinct execution that may partially
  #      succeed; collapsing them makes it impossible to tell which wrote what.
  module JobContext
    extend ActiveSupport::Concern

    included do
      # Enqueue only after the enclosing transaction commits. Without this, a job
      # enqueued inside a transaction that later rolls back STILL RUNS, and its
      # writes get attributed to a user action that never happened.
      #
      # This must be set on the job class. `config.active_job.enqueue_after_
      # transaction_commit` in application.rb is explicitly filtered out of the
      # global config by ActiveJob's railtie ("This config can't be applied
      # globally") and silently does nothing -- verified in activejob 8.1.3.1,
      # railtie.rb:58-64.
      self.enqueue_after_transaction_commit = true

      around_perform do |job, block|
        origin = job.audit_origin || {}

        AuditLog::Current.set(
          request_id:           AuditLog::Context.new_request_id,
          caused_by_request_id: origin["request_id"],
          actor_type:           origin["actor_type"],
          actor_id:             origin["actor_id"],
          actor_label:          origin["actor_label"],
          # No origin at all means nobody enqueued this: it came from the
          # scheduler. An auditor needs "the schedule did this" to look different
          # from "a user's request caused this".
          source:               origin.present? ? "job" : "system"
        ) { block.call }
      end
    end

    attr_accessor :audit_origin

    # Captured in `serialize`, NOT in an around_enqueue callback.
    #
    # ActiveJob.perform_all_later and Solid Queue's enqueue_all are documented as
    # skipping the enqueue callbacks, so an around_enqueue hook would silently
    # drop the actor on every bulk enqueue. `serialize` runs on every enqueue
    # path. The `||=` means a retry keeps the ORIGINAL origin rather than
    # recapturing the retrying worker's context.
    def serialize
      self.audit_origin ||= {
        "request_id"  => AuditLog::Current.request_id,
        "actor_type"  => AuditLog::Current.actor_type,
        "actor_id"    => AuditLog::Current.actor_id,
        "actor_label" => AuditLog::Current.actor_label,
        "source"      => AuditLog::Current.source
      }.compact

      super.merge("audit_origin" => audit_origin)
    end

    def deserialize(job_data)
      super
      self.audit_origin = job_data["audit_origin"]
    end
  end
end
