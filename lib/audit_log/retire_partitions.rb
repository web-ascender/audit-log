# frozen_string_literal: true

module AuditLog
  # Retention, as a job: DETACH and mark retired whatever has passed
  # config.retention. Never drops. Monthly, in a LOW-TRAFFIC WINDOW -- it takes
  # ACCESS EXCLUSIVE on an audit table, which blocks every audited write while it
  # runs.
  #
  # Lock contention and lock timeouts raise, so a bad moment is a failed job and
  # a retry NEXT CYCLE. A backend that retries failed jobs on its own (Sidekiq
  # does by default) re-runs this outside the window; on such a backend write
  # your own job, with retries off, around AuditLog::Maintenance.retire_partitions!.
  #
  # Why ActiveJob::Base, no JobContext, no queue_as and no retry_on: see
  # RotatePartitions.
  class RetirePartitions < ActiveJob::Base
    def perform
      Maintenance.retire_partitions!
    end
  end
end
