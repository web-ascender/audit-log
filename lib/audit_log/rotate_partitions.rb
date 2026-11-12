# frozen_string_literal: true

module AuditLog
  # The daily partition run, as a job for config/recurring.yml or a sidekiq-cron
  # schedule. Schedule it DAILY: a missing future partition is a write-path
  # outage. It FAILS when the run finds rows misfiled (MaintenanceWarning), which
  # is the point -- see AuditLog::Maintenance, where the behaviour lives.
  #
  # Three things about this class look like omissions and are not (DESIGN §8,
  # "Scheduling from a job queue"):
  #
  #   ActiveJob::Base, not ApplicationJob. The gem never names a host constant.
  #   A host wanting its own base class, retries or a heartbeat writes its own
  #   job around AuditLog::Maintenance.rotate_partitions! -- documented, not a
  #   workaround.
  #
  #   No JobContext. Nothing a partition run does writes an audited row, so
  #   there is no actor to carry, and with Current empty the session stamp
  #   resets rather than inheriting the previous job's.
  #
  #   No queue_as. ActiveJob's "default" is the one queue every Sidekiq
  #   process consumes unless told otherwise; a named queue nobody listens on
  #   would leave this job enqueued forever, and the first symptom would be the
  #   outage it exists to prevent. Set `queue:` on the schedule entry instead.
  #
  #   No retry_on. Solid Queue retries nothing, so tomorrow's run is the retry.
  #   Sidekiq retries by default, and a warning persists until somebody drains,
  #   so every daily failure would breed weeks of retries and an error report
  #   each -- the alert fatigue the warning/note line exists to avoid. On
  #   Sidekiq, write your own job with retries off around the routine.
  #
  # Lives in lib/ and loads only when named, so an app that never loaded
  # ActiveJob is unaffected by its existence.
  class RotatePartitions < ActiveJob::Base
    def perform
      Maintenance.rotate_partitions!
    end
  end
end
