# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # The ENTIRE background-job integration. Inheriting from ApplicationJob is all
  # a job has to do to participate; there is nothing per-job. A job that inherits
  # directly from ActiveJob::Base is the only way to lose correlation, which
  # spec/audit_log/job_correlation_spec.rb catches.
  include AuditLog::JobContext

  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3
  discard_on ActiveJob::DeserializationError

  # Close the narrative loop: a job that mutates data but emits no domain event
  # would produce change rows with no action row and show up in the reconciler
  # forever. Cost is one audit_events row per execution; a high-volume,
  # non-mutating job can opt out with `skip_audit_event!`, which reduces
  # narrative noise and never reduces audit coverage -- the triggers fire either
  # way.
  class_attribute :emit_audit_event, default: true

  def self.skip_audit_event!
    self.emit_audit_event = false
  end

  around_perform do |job, block|
    block.call
    if emit_audit_event
      AuditLog.notify("job.performed",
        job_class: job.class.name, job_id: job.job_id, executions: job.executions)
    end
  end
end
