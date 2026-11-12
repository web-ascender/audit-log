# frozen_string_literal: true

module AuditLog
  # Rollup, as a job: consolidate closed years of monthly partitions into yearly
  # ones, past config.rollup_after. Monthly or quarterly, in a LOW-TRAFFIC
  # WINDOW -- it rewrites a year of data and takes ACCESS EXCLUSIVE for the swap.
  #
  # Same retry caveat as RetirePartitions, and the same reasons for
  # ActiveJob::Base, no JobContext, no queue_as and no retry_on as
  # RotatePartitions.
  class RollUpPartitions < ActiveJob::Base
    def perform
      Maintenance.roll_up_partitions!
    end
  end
end
