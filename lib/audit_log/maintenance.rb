# frozen_string_literal: true

module AuditLog
  # The three partition routines worth scheduling, as plain Ruby: rotation daily,
  # retention and rollup monthly. DESIGN §8, "Scheduling from a job queue".
  #
  # The rake tasks call these. So do AuditLog::RotatePartitions, RetirePartitions
  # and RollUpPartitions, which exist so an app on Solid Queue or sidekiq-cron
  # can schedule them without shelling out. So can a host's own job -- the
  # documented path when it wants its own base class, queue, retry policy or a
  # heartbeat around the run, none of which this library should guess at.
  #
  # NOTHING HERE TOUCHES ActiveJob. The jobs live in their own files and load
  # only when named, so the rake tasks keep working in an app that never loaded
  # ActiveJob, and an app that never schedules a job never loads one.
  #
  # ---------------------------------------------------------------------------
  # WHAT A ROUTINE SAYS goes to a reporter AS IT HAPPENS, never collected and
  # handed back at the end -- the reason `retire!` and `rollup!` yield as each
  # partition commits. Rotation reports everything BEFORE it freezes, so a
  # VACUUM that raises cannot take a warning or a note down with it -- and if
  # there was a warning, the failure it raises carries it (MaintenanceWarning).
  #
  # Three levels, and the line between the last two is the one that matters:
  #
  #   info     what it did.
  #   note     disk held by something awaiting a human decision -- a retired
  #            partition, a lookalike carrying no marker, an unfinished rollup's
  #            staging table. Real, and never urgent.
  #   warning  the partition layout is misfiling rows or will block provisioning
  #            -- rows in a default partition, a boundary off UTC midnight.
  #
  # An unfinished rollup was a WARNING when this lived in the rake task. It is a
  # note because the line is "does this threaten the write path", and a staging
  # table is disk: the rollup run that left it already failed loudly, and the
  # next rollup run reclaims it.
  #
  # ---------------------------------------------------------------------------
  # rotate_partitions! RAISES MaintenanceWarning when there was a warning, AFTER
  # all its work is done -- so a misaligned boundary never costs a month its
  # freeze. A job's only channel anybody watches is whether it failed (Solid
  # Queue's failed executions, an error tracker, a check-in), and a warning
  # written to a worker log is a scheduler discarding output: the silent skip
  # the README warns about, arrived at through a job queue.
  #
  # The rake task passes `raise_on_warnings: false`, because a cron's channel is
  # the task's OUTPUT -- stderr, mailed or captured -- and its exit status has
  # always been 0 on a warning. Each surfaces through what its environment
  # watches; the routine itself is the same.
  #
  # Notes never raise. The daily job is the one whose failure means "the write
  # path is at risk", and failing it every day over disk somebody has not yet
  # reclaimed teaches a team to ignore it -- the reason `audit_log:benchmark`
  # does not flag a seq scan on a near-empty partition.
  module Maintenance
    class << self
      # The daily routine. Creates missing partitions and the default backstop,
      # reports what it finds, then freezes newly closed months -- the freeze
      # LAST, so everything there is to say has been said if it fails.
      #
      # Returns {created:, frozen:, warnings:}, the last only reachable when
      # raise_on_warnings is false.
      def rotate_partitions!(reporter: LogReporter.new, raise_on_warnings: true,
                             connection: ActiveRecord::Base.connection)
        # Every warning goes through the tally, so one sent any other way cannot
        # be logged and yet fail to fail the job.
        reporter = Tally.new(reporter)
        schema   = current_schema(connection)

        created = Partitions.ensure!(connection: connection)
        reporter.info(created.any? ? "Created: #{created.join(", ")}" : "All partitions present.")

        Partitions.overflow_count(connection: connection).each do |table, count|
          next if count.zero?

          reporter.warning(
            "#{count} row(s) in #{qualified(schema, "#{table}_default")} -- a monthly partition " \
            "was missing when they were written. Attaching a partition covering their range " \
            "will fail until they are relocated with `rake audit_log:partitions:drain_default`."
          )
        end

        # Every boundary must be UTC midnight, or adjacent months overlap (CREATE
        # fails) or leave a gap (rows land in the default partition, which then
        # blocks attaching the real one). A hit here means a partition was created
        # from a session whose TimeZone was not UTC.
        Partitions.misaligned_bounds(connection: connection).each do |b|
          reporter.warning(
            "#{qualified(schema, b[:name])} is not UTC-aligned -- covers #{b[:lower].iso8601} " \
            "to #{b[:upper].iso8601}. Expect a gap or an overlap at the month boundary; " \
            "see AuditLog::Partitions."
          )
        end

        Partitions.retired_partitions(connection: connection).each do |r|
          reporter.note("#{qualified(schema, r[:name])} is detached and still occupying " \
                        "#{human_size(r[:bytes])}. Export it and drop it.")
        end

        note_unmarked_retired(reporter, connection: connection)

        # Not partitions and not in `list`, so nothing else would ever mention
        # them -- while each holds a full year of audit data.
        Partitions.orphaned_rollups(connection: connection).each do |r|
          reporter.note("#{qualified(schema, r[:name])} is a staging table left by a rollup " \
                        "that did not finish, occupying #{human_size(r[:bytes])}. Re-run " \
                        "`rake audit_log:partitions:rollup` to reclaim it.")
        end

        # FREEZING RUNS LAST. After creation, because creation is the
        # safety-critical half -- a missing future partition is a write-path
        # outage -- so it has committed already, and a VACUUM that turns out slow
        # or fails cannot delay it. After the inventory, so a VACUUM that raises
        # cannot stop anything above being said.
        #
        # Bounded by the frozen marker: on most days this is two catalog queries
        # and no work, on the first run of a month exactly one partition per
        # table. That is what makes it safe to do daily, and it takes "when should
        # I run freeze?" away from the operator entirely.
        begin
          frozen = Partitions.freeze_closed!(connection: connection)
        rescue StandardError => error
          # A failed freeze must not become the only thing the job reports. Left
          # alone it would fail as a VACUUM error and the misfiled rows -- the
          # finding that needs a person -- would exist only in the worker log.
          # Raised from inside the rescue, so the VACUUM error is its `cause`.
          raise unless raise_on_warnings && reporter.warnings.any?

          raise MaintenanceWarning.new(reporter.warnings, failure: error)
        end
        reporter.info("Froze: #{frozen.join(", ")}") if frozen.any?

        raise MaintenanceWarning.new(reporter.warnings) if raise_on_warnings && reporter.warnings.any?

        { created: created, frozen: frozen, warnings: reporter.warnings }
      end

      # DETACH everything past config.retention and mark it retired. Never
      # drops -- see Partitions.retire!. Takes ACCESS EXCLUSIVE on an audit
      # table, so it belongs in a low-traffic window, and lock contention or a
      # lock timeout RAISES rather than queueing.
      #
      # Returns what it retired; nothing on a dry run or when disabled.
      def retire_partitions!(reporter: LogReporter.new, dry_run: false,
                             connection: ActiveRecord::Base.connection)
        retention = AuditLog.config.retention
        if retention.nil?
          reporter.info("Retention is disabled (AuditLog.config.retention is nil).")
          return []
        end

        expired = Partitions.expired_partitions(connection: connection, retention: retention)
        reporter.info("Horizon: #{retention.inspect} -- anything ending before " \
                      "#{(Time.now.utc - retention).iso8601} is expired.")

        if expired.empty?
          reporter.info("Nothing expired.")
          return []
        end

        if dry_run
          expired.each do |b|
            reporter.info("  would detach: #{b[:name]} (#{b[:lower].to_date} .. #{b[:upper].to_date})")
          end
          return []
        end

        # Reported from the block, as each partition commits: every one is its own
        # transaction, so a failure partway through leaves the earlier ones
        # already retired, and the operator has to be told which.
        retired = Partitions.retire!(connection: connection, retention: retention) do |r|
          reporter.info("  detached: #{r[:name]} -> #{r[:retired_as]}")
        end
        reporter.note("Retired partitions still hold their data. Export and/or drop them; " \
                      "`rake audit_log:partitions` lists them.")
        retired
      end

      # Consolidate closed years of monthly partitions into yearly ones. Rewrites
      # a full year of data and takes ACCESS EXCLUSIVE for the swap: a monthly or
      # quarterly window, not the daily run.
      #
      # Returns what it rolled up; nothing on a dry run or when disabled.
      def roll_up_partitions!(reporter: LogReporter.new, dry_run: false,
                              connection: ActiveRecord::Base.connection)
        if AuditLog.config.rollup_after.nil?
          reporter.info("Rollup is disabled (AuditLog.config.rollup_after is nil).")
          return []
        end

        candidates = Partitions.rollup_candidates(connection: connection)
        if candidates.empty?
          reporter.info("No closed year is stored as monthly partitions.")
          return []
        end

        candidates.each do |c|
          reporter.info("#{c[:table]} #{c[:year]}: #{c[:partitions].size} monthly partition(s) -> " \
                        "#{Partitions.year_partition_name(c[:table], c[:year])}")
        end

        if dry_run
          reporter.info("DRY_RUN -- nothing changed.")
          return []
        end

        Partitions.rollup!(connection: connection) do |r|
          reporter.info("  #{r[:name]}: #{r[:rows]} row(s), replaced #{r[:replaced].size} " \
                        "monthly partition(s)")
        end.compact
      end

      # Reported rather than silently skipped, for the reason orphaned rollups
      # are: an invisible cost is one nobody reclaims. A table that LOOKS retired
      # and carries no marker of ours is either somebody's manual copy that we
      # correctly refused to touch, or a partition this library can no longer
      # manage -- and in both cases the disk it holds will never be freed by
      # anything here.
      #
      # Public because the drop tasks say it too.
      def note_unmarked_retired(reporter, connection: ActiveRecord::Base.connection)
        schema = current_schema(connection)

        Partitions.unmarked_retired(connection: connection).each do |r|
          reporter.note("#{qualified(schema, r[:name])} looks retired but carries no #{Partitions::RETIRED_MARKER} " \
                        "marker, so nothing here will export or drop it. #{human_size(r[:bytes])}. " \
                        "Either this library did not retire it, or its comment was lost. " \
                        "Drop it by hand if it is yours.")
        end
      end

      private

      def human_size(bytes)
        ActiveSupport::NumberHelper.number_to_human_size(bytes)
      end

      # Everything here acts on current_schema() (DESIGN §14), so in a loop over
      # tenants a bare `audit_changes_default` says which table and not whose.
      # Qualified only off `public`, so a single-schema app reads as it always has.
      def current_schema(connection)
        connection.select_value("SELECT current_schema()")
      end

      def qualified(schema, name)
        schema.nil? || schema == "public" ? name : "#{schema}.#{name}"
      end
    end

    # Passes everything through and keeps the warnings, so the routine has one
    # place that knows what was warned. Private: a reporter is the host's to
    # supply, this is how rotation reads one back.
    class Tally
      attr_reader :warnings

      def initialize(reporter)
        @reporter = reporter
        @warnings = []
      end

      def info(message) = @reporter.info(message)
      def note(message) = @reporter.note(message)

      def warning(message)
        @warnings << message
        @reporter.warning(message)
      end
    end
    private_constant :Tally

    # The default: what the jobs use, and what a host's own job gets without
    # asking. Warnings are only logged here; rotate_partitions! raising on them is
    # what reaches somebody.
    class LogReporter
      def initialize(logger: Rails.logger)
        @logger = logger
      end

      def info(message)    = @logger&.info("[AuditLog] #{message}")
      def note(message)    = @logger&.warn("[AuditLog] NOTE: #{message}")
      def warning(message) = @logger&.warn("[AuditLog] WARNING: #{message}")
    end

    # The rake tasks'. stdout for what was done, stderr for the rest, which is the
    # split a cron's MAILTO or a log shipper already understands. $stderr.puts
    # rather than Kernel#warn, which prints nothing when $VERBOSE is nil.
    class ConsoleReporter
      def info(message)    = $stdout.puts(message)
      def note(message)    = $stderr.puts("NOTE: #{message}")
      def warning(message) = $stderr.puts("WARNING: #{message}")
    end
  end

  # Raised by Maintenance.rotate_partitions! when the run found the partition
  # layout misfiling rows -- after completing, or, if the freeze then failed,
  # carrying that failure as its `cause` and the tail of its message. Its own
  # class so a host can rescue it, or tell its error tracker to group it, apart
  # from a run that failed and found nothing wrong.
  class MaintenanceWarning < Error
    attr_reader :warnings

    def initialize(warnings, failure: nil)
      @warnings = Array(warnings)
      message = @warnings.join(" ")
      message += " The run then failed: #{failure.class}: #{failure.message}" if failure
      super(message)
    end
  end
end
