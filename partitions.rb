# frozen_string_literal: true

module AuditLog
  # Monthly range partitions on occurred_at for both audit tables, plus the three
  # lifecycle operations a long retention horizon needs: draining the default
  # partition, rolling closed months up into years, and retiring expired ranges.
  #
  # Partition pruning is the entire performance story for the auditor screens
  # (plan §11.0 Rule 1), and a missing FUTURE partition is a write-path outage --
  # every audited INSERT/UPDATE/DELETE in the application starts failing. So:
  #
  #   * `ensure!` provisions several months ahead and is safe to run repeatedly.
  #   * A DEFAULT partition is created as a backstop, `overflow_count` reports
  #     rows that landed in it, and `drain_default!` relocates them.
  #
  # EVERY BOUNDARY IS UTC MIDNIGHT. This is an invariant of the library, not a
  # preference, and `misaligned_bounds` exists to enforce it. Two reasons:
  #
  #   1. `occurred_at` is timestamptz filled by clock_timestamp() -- an absolute
  #      instant with no zone of its own. UTC is the only boundary that is not an
  #      arbitrary choice.
  #   2. UTC has no DST. A boundary defined in a zone that observes DST is either
  #      23 or 25 hours from its neighbour twice a year, which means adjacent
  #      months can overlap (CREATE fails) or leave a gap (rows silently land in
  #      the default partition, which then BLOCKS attaching the real one).
  #
  # Note the deliberate asymmetry with AuditLog::DateRange, which builds its
  # bounds in Time.zone: a UI date filter is a human's calendar day and belongs in
  # the app's zone, while a storage boundary belongs in UTC. The cost is that an
  # app-zone month straddles a UTC boundary and touches one extra partition. That
  # is a known +1, not a bug -- see the comment in date_range.rb.
  #
  # ---------------------------------------------------------------------------
  # WHICH OPERATIONS TAKE AN EXCLUSIVE LOCK
  #
  # `ensure!` does not: CREATE TABLE ... PARTITION OF takes ACCESS EXCLUSIVE on
  # the parent only for the catalog update, and there is nothing to scan. It is
  # safe on a live system and is the one that runs daily.
  #
  # `drain_default!`, `rollup_year!`'s swap, and `retire!` DO take ACCESS
  # EXCLUSIVE on the parent, which blocks every audited write in the application
  # for the duration. All three run under `config.maintenance_lock_timeout` so
  # they fail fast instead of forming a queue behind a long-running transaction,
  # and none of them are wired into the daily task. Run them deliberately.
  module Partitions
    TABLES = %w[audit_events audit_changes].freeze

    # Detached-but-kept partitions are renamed into this infix rather than left
    # under their original name, so that "expired, awaiting export" is a visible
    # state rather than an invisible one, and so `exists?` in create_month! can
    # never mistake a retired table for a live partition.
    RETIRED_INFIX = "retired"

    class << self
      def ensure!(connection: ActiveRecord::Base.connection, months_ahead: nil, months_back: 1)
        months_ahead ||= AuditLog.config.partition_months_ahead
        created = []

        TABLES.each do |table|
          create_default!(table, connection: connection)
          (-months_back..months_ahead).each do |offset|
            created << create_month!(table, current_month >> offset, connection: connection)
          end
        end

        created.compact
      end

      def create_month!(table, month, connection: ActiveRecord::Base.connection)
        month = month.to_date.beginning_of_month
        name  = partition_name(table, month)
        return nil if exists?(name, connection: connection)

        connection.execute(<<~SQL)
          CREATE TABLE #{connection.quote_table_name(name)}
          PARTITION OF #{connection.quote_table_name(table)}
          FOR VALUES FROM (#{connection.quote(utc_midnight(month))})
                       TO (#{connection.quote(utc_midnight(month >> 1))})
        SQL
        name
      end

      # A rolled-back rotation job should not take the application's write path
      # down with it, so writes outside every defined range land here instead of
      # raising. The cost: while rows sit in the default partition, ATTACHing a
      # new partition covering their range fails, because Postgres must scan the
      # default partition and reject overlapping rows. `overflow_count` exists to
      # make that condition loud rather than latent, and `drain_default!` to
      # resolve it.
      def create_default!(table, connection: ActiveRecord::Base.connection)
        name = "#{table}_default"
        return nil if exists?(name, connection: connection)

        connection.execute(<<~SQL)
          CREATE TABLE #{connection.quote_table_name(name)}
          PARTITION OF #{connection.quote_table_name(table)} DEFAULT
        SQL
        name
      end

      def overflow_count(connection: ActiveRecord::Base.connection)
        TABLES.index_with do |table|
          connection.select_value("SELECT count(*) FROM #{table}_default").to_i
        end
      end

      # ---------------------------------------------------------------- drain
      # Move every row out of the default partition into the partition that
      # should have held it, creating those partitions on the way.
      #
      # The order is forced and is the whole reason this is not a one-liner: a
      # partition covering a range cannot be created while the default partition
      # holds rows in that range (Postgres validates the default's implied
      # constraint and refuses). So the rows must come OUT first, into a staging
      # table, and go back in only once the real partitions exist. All of it in
      # one transaction, so a failure anywhere leaves the rows in the default
      # partition -- exactly where they started, still queryable through the
      # parent, nothing lost.
      def drain_default!(connection: ActiveRecord::Base.connection)
        TABLES.index_with { |table| drain_table_default!(table, connection: connection) }
      end

      # ------------------------------------------------------------ retention
      # Partitions whose range lies entirely outside the retention horizon.
      #
      # Keyed on the UPPER bound, never the lower: a partition is only expired
      # once its NEWEST possible row is older than the horizon. Using the lower
      # bound would drop a month that still contains in-horizon days.
      def expired_partitions(connection: ActiveRecord::Base.connection,
                             retention: AuditLog.config.retention)
        return [] if retention.nil?

        cutoff = Time.now.utc - retention
        partition_bounds(connection: connection).select { |b| b[:upper] <= cutoff }
      end

      # DETACH (and optionally DROP) everything past the retention horizon.
      #
      # The default action is :detach, not :drop, and that asymmetry is
      # deliberate: detaching is reversible with a single ATTACH, so a wrong
      # retention setting costs an afternoon. Dropping is not, and an audit log is
      # the worst table in the database to discover a wrong setting in. Detached
      # partitions keep their data and stay in the schema under a `_retired_`
      # name; `retired_partitions` reports them so they cannot pile up unseen.
      # Set config.retention_action = :drop once an export step exists.
      def retire!(connection: ActiveRecord::Base.connection,
                  retention: AuditLog.config.retention,
                  action: AuditLog.config.retention_action)
        raise Error, "unknown retention_action #{action.inspect}" unless %i[detach drop].include?(action)

        expired_partitions(connection: connection, retention: retention).map do |bound|
          name    = bound[:name]
          table   = parent_table_for(name)
          retired = retired_name(table, name)

          with_lock_timeout(connection) do
            connection.transaction do
              connection.execute(
                "ALTER TABLE #{connection.quote_table_name(table)} " \
                "DETACH PARTITION #{connection.quote_table_name(name)}"
              )
              if action == :drop
                connection.execute("DROP TABLE #{connection.quote_table_name(name)}")
              else
                connection.execute(
                  "ALTER TABLE #{connection.quote_table_name(name)} " \
                  "RENAME TO #{connection.quote_table_name(retired)}"
                )
              end
            end
          end

          bound.merge(action: action, retired_as: (retired unless action == :drop))
        end
      end

      # Detached-but-kept partitions still occupying disk. Anything here is
      # waiting on an export-and-drop decision.
      def retired_partitions(connection: ActiveRecord::Base.connection)
        connection.select_all(<<~SQL).to_a.map { |r| { name: r["name"], bytes: r["bytes"].to_i } }
          SELECT c.relname AS name, pg_total_relation_size(c.oid) AS bytes
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  n.nspname = 'public'
            AND  c.relkind = 'r'
            AND  (c.relname LIKE 'audit_events_#{RETIRED_INFIX}_%'
                  OR c.relname LIKE 'audit_changes_#{RETIRED_INFIX}_%')
          ORDER  BY c.relname
        SQL
      end

      # --------------------------------------------------------------- rollup
      # Calendar years old enough to consolidate, and still stored as months.
      #
      # 84 monthly partitions per table is what a 7-year horizon produces, and
      # every one of them is a relation the planner considers, autovacuum tracks,
      # and pg_dump walks. Rolling closed years up trades that down to ~5 yearly
      # partitions plus a rolling window of months.
      def rollup_candidates(connection: ActiveRecord::Base.connection,
                            older_than: AuditLog.config.rollup_after)
        return [] if older_than.nil?

        cutoff = Time.now.utc - older_than
        bounds = partition_bounds(connection: connection)

        TABLES.flat_map do |table|
          months = bounds.select { |b| b[:name].start_with?("#{table}_") && month_from_name(b[:name]) }

          months.group_by { |b| month_from_name(b[:name]).year }
                .select { |year, _| Time.utc(year + 1) <= cutoff }
                .reject { |year, _| exists?(year_partition_name(table, year), connection: connection) }
                .map    { |year, ms| { table: table, year: year, partitions: ms.map { |m| m[:name] }.sort } }
        end
      end

      def rollup!(connection: ActiveRecord::Base.connection,
                  older_than: AuditLog.config.rollup_after)
        rollup_candidates(connection: connection, older_than: older_than).map do |candidate|
          rollup_year!(candidate[:table], candidate[:year], connection: connection)
        end
      end

      # Replace one calendar year's monthly partitions with a single yearly one.
      #
      # Postgres has no ALTER TABLE ... MERGE PARTITIONS: the patch was reverted
      # before 17 shipped and is absent from 18, so this is a copy-and-swap.
      #
      # It is staged so the exclusive lock covers the catalog work only, not the
      # data copy. Phase 1 builds and fills a standalone table -- the parent is
      # untouched and the application keeps writing. Phase 2 detaches the twelve
      # months, attaches the new table, and drops them, in one short transaction.
      #
      # Correctness rests on the year being closed, which `rollup_candidates`
      # guarantees by only offering years older than config.rollup_after. That
      # assumption is asserted rather than trusted: an id watermark taken BEFORE
      # the copy is re-checked after the detach, and a single row that arrived in
      # between rolls the whole swap back. Taken before, not after, on purpose --
      # a watermark read after the copy would not catch a row that landed during
      # it, which is precisely the row that would be lost.
      def rollup_year!(table, year, connection: ActiveRecord::Base.connection)
        target = year_partition_name(table, year)
        lower  = Time.utc(year)
        upper  = Time.utc(year + 1)
        # Literals with an explicit +00, never a quoted Time: a bare timestamp
        # literal is resolved against the session TimeZone, which is the exact
        # hazard the UTC-midnight invariant exists to remove.
        lo_lit = connection.quote(utc_midnight(lower.to_date))
        hi_lit = connection.quote(utc_midnight(upper.to_date))

        raise Error, "#{target} is already a partition of #{table}" if attached?(target, connection: connection)

        monthlies = partition_bounds(connection: connection).select do |b|
          b[:name].start_with?("#{table}_") && month_from_name(b[:name]) &&
            b[:lower] >= lower && b[:upper] <= upper
        end
        return nil if monthlies.empty?

        # ATTACH must scan the default partition to prove no row there belongs in
        # the incoming range. Checking first turns a late, cryptic failure at the
        # end of a long copy into an immediate, actionable one.
        stray = connection.select_value(<<~SQL).to_i
          SELECT count(*) FROM #{connection.quote_table_name("#{table}_default")}
          WHERE occurred_at >= #{lo_lit} AND occurred_at < #{hi_lit}
        SQL
        if stray.positive?
          raise Error, "#{table}_default holds #{stray} row(s) in #{year}; " \
                       "run AuditLog::Partitions.drain_default! first"
        end

        watermark = connection.select_value(<<~SQL).to_i
          SELECT coalesce(max(id), 0) FROM #{connection.quote_table_name(table)}
          WHERE occurred_at >= #{lo_lit} AND occurred_at < #{hi_lit}
        SQL

        # ---- phase 1: build and fill, holding no lock on the parent ----------
        # A leftover target from an interrupted earlier run holds nothing the
        # parent does not, since it is not attached. Recreating is the safe reset.
        connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name(target)}")

        # INCLUDING ALL carries the indexes, so ATTACH matches them against the
        # parent's partitioned indexes instead of rebuilding them under the lock.
        connection.execute(<<~SQL)
          CREATE TABLE #{connection.quote_table_name(target)}
          (LIKE #{connection.quote_table_name(table)} INCLUDING ALL)
        SQL
        connection.execute(<<~SQL)
          INSERT INTO #{connection.quote_table_name(target)}
          SELECT * FROM #{connection.quote_table_name(table)}
          WHERE occurred_at >= #{lo_lit} AND occurred_at < #{hi_lit}
        SQL

        # A validated CHECK matching the future partition bound lets ATTACH skip
        # its own full-table validation scan. Validating it here costs the same
        # scan but pays it outside the exclusive lock.
        constraint = "#{target}_bound"
        connection.execute(<<~SQL)
          ALTER TABLE #{connection.quote_table_name(target)}
          ADD CONSTRAINT #{connection.quote_table_name(constraint)}
          CHECK (occurred_at >= #{lo_lit} AND occurred_at < #{hi_lit})
        SQL
        connection.execute("ANALYZE #{connection.quote_table_name(target)}")

        moved = connection.select_value("SELECT count(*) FROM #{connection.quote_table_name(target)}").to_i

        # ---- phase 2: the swap, under ACCESS EXCLUSIVE, catalog work only ----
        with_lock_timeout(connection) do
          connection.transaction do
            monthlies.each do |m|
              connection.execute(
                "ALTER TABLE #{connection.quote_table_name(table)} " \
                "DETACH PARTITION #{connection.quote_table_name(m[:name])}"
              )
            end

            late = monthlies.sum do |m|
              connection.select_value(
                "SELECT count(*) FROM #{connection.quote_table_name(m[:name])} WHERE id > #{watermark}"
              ).to_i
            end
            if late.positive?
              raise Error, "#{late} row(s) were written to #{table} in #{year} during the rollup copy; " \
                           "the year is not closed. Rolled back, nothing changed."
            end

            connection.execute(<<~SQL)
              ALTER TABLE #{connection.quote_table_name(table)}
              ATTACH PARTITION #{connection.quote_table_name(target)}
              FOR VALUES FROM (#{lo_lit}) TO (#{hi_lit})
            SQL

            # Redundant with the partition constraint once attached, and the
            # planner has to consider it on every query against the parent.
            connection.execute(
              "ALTER TABLE #{connection.quote_table_name(target)} " \
              "DROP CONSTRAINT #{connection.quote_table_name(constraint)}"
            )

            monthlies.each do |m|
              connection.execute("DROP TABLE #{connection.quote_table_name(m[:name])}")
            end
          end
        end

        { table: table, year: year, name: target, rows: moved, replaced: monthlies.map { |m| m[:name] } }
      end

      # --------------------------------------------------------------- vacuum
      # Once a partition's range closes it never changes again, so freezing it
      # deterministically beats waiting for an anti-wraparound vacuum to storm
      # through the largest table in the database months later. On PG 18 eager
      # freezing handles the current partition too; this still helps closed ones.
      #
      # Driven off real bounds rather than the name, so a yearly partition
      # produced by rollup_year! is covered without special-casing.
      def freeze_closed!(connection: ActiveRecord::Base.connection)
        cutoff = current_month.to_time(:utc)

        partition_bounds(connection: connection).select { |b| b[:upper] <= cutoff }.map do |b|
          connection.execute("VACUUM (FREEZE, ANALYZE) #{connection.quote_table_name(b[:name])}")
          b[:name]
        end
      end

      # ------------------------------------------------------------ inventory
      def list(connection: ActiveRecord::Base.connection)
        connection.select_values(<<~SQL)
          SELECT c.relname
          FROM   pg_class c
          JOIN   pg_inherits i ON i.inhrelid = c.oid
          JOIN   pg_class p ON p.oid = i.inhparent
          WHERE  p.relname IN ('audit_events', 'audit_changes')
          ORDER  BY c.relname
        SQL
      end

      # The actual range each partition covers, as Time objects in UTC.
      #
      # Read back out of pg_get_expr rather than recomputed from the name, so this
      # reports what Postgres will really route on. The rendered literal always
      # carries an explicit UTC offset, so the ::timestamptz cast round-trips
      # regardless of the session TimeZone doing the reading.
      def partition_bounds(connection: ActiveRecord::Base.connection)
        connection.select_all(<<~SQL).to_a.map do |row|
          SELECT c.relname AS name,
                 (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \\(''([^'']+)''\\)'))[1]::timestamptz AS lower,
                 (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \\(''([^'']+)''\\)'))[1]::timestamptz   AS upper
          FROM   pg_class c
          JOIN   pg_inherits i ON i.inhrelid = c.oid
          JOIN   pg_class p ON p.oid = i.inhparent
          WHERE  p.relname IN ('audit_events', 'audit_changes')
            AND  pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT'
          ORDER  BY c.relname
        SQL
          { name: row["name"], lower: row["lower"].utc, upper: row["upper"].utc }
        end
      end

      # Any partition whose range is not exactly the calendar month or year its
      # name claims, on UTC midnight boundaries. A non-empty result means someone
      # created a partition from a session whose TimeZone was not UTC -- by hand
      # in psql, or from a host app that overrides the connection timezone. Left
      # alone it produces a gap or an overlap at the boundary; see the module
      # comment.
      def misaligned_bounds(connection: ActiveRecord::Base.connection)
        partition_bounds(connection: connection).reject do |b|
          # A name that parses as neither a month nor a year is not something this
          # library created, so it has no expected bounds to check against.
          # Returning true excludes it from the report rather than flagging it.
          expected = expected_bounds(b[:name]) or next true
          b[:lower] == expected.first && b[:upper] == expected.last
        end
      end

      def partition_name(table, month)
        format("%s_%04d_%02d", table, month.year, month.month)
      end

      def year_partition_name(table, year)
        format("%s_%04d", table, year)
      end

      private

      def drain_table_default!(table, connection:)
        default = "#{table}_default"
        result  = { moved: 0, created: [] }
        return result unless exists?(default, connection: connection)

        with_lock_timeout(connection) do
          connection.transaction do
            # The parent before the default, matching the order an ordinary INSERT
            # takes them, so a concurrent write queues instead of deadlocking.
            connection.execute("LOCK TABLE #{connection.quote_table_name(table)} IN ACCESS EXCLUSIVE MODE")
            connection.execute("LOCK TABLE #{connection.quote_table_name(default)} IN ACCESS EXCLUSIVE MODE")

            # `AT TIME ZONE 'UTC'` before date_trunc, so the month a row is filed
            # under is the same month the partition bounds were cut on. date_trunc
            # applied directly to a timestamptz truncates in the session zone.
            months = connection.select_values(<<~SQL).map(&:to_date)
              SELECT DISTINCT date_trunc('month', occurred_at AT TIME ZONE 'UTC')::date
              FROM #{connection.quote_table_name(default)}
              ORDER BY 1
            SQL
            next result if months.empty?

            staging = "_audit_log_drain_#{table}"
            connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name(staging)}")
            connection.execute(<<~SQL)
              CREATE TEMP TABLE #{connection.quote_table_name(staging)}
              (LIKE #{connection.quote_table_name(table)}) ON COMMIT DROP
            SQL

            moved = connection.select_value(<<~SQL).to_i
              WITH moved AS (DELETE FROM #{connection.quote_table_name(default)} RETURNING *),
                   staged AS (INSERT INTO #{connection.quote_table_name(staging)} SELECT * FROM moved RETURNING 1)
              SELECT count(*) FROM staged
            SQL

            # A month already inside a yearly partition needs no monthly one, and
            # creating an overlapping partition would fail.
            covered = partition_bounds(connection: connection).select { |b| b[:name].start_with?("#{table}_") }
            months.each do |month|
              start = month.to_time(:utc)
              next if covered.any? { |b| b[:lower] <= start && start < b[:upper] }

              result[:created] << create_month!(table, month, connection: connection)
            end
            result[:created].compact!

            connection.execute(<<~SQL)
              INSERT INTO #{connection.quote_table_name(table)}
              SELECT * FROM #{connection.quote_table_name(staging)}
            SQL

            result[:moved] = moved
            result
          end
        end

        result
      end

      # Which months to provision and which are closed must be decided in UTC,
      # because that is where the boundaries are. Date.current follows Time.zone;
      # in an app configured to a US zone it is hours BEHIND UTC, so on the last
      # day of a month it names the previous month and the arithmetic drifts one
      # partition out of step with the data.
      def current_month
        Time.now.utc.to_date.beginning_of_month
      end

      # An explicit +00 rather than a bare "2026-09-01". A bare date literal is
      # resolved against the session TimeZone AT DDL TIME, so the same code run
      # from psql (server default zone) and from Rails (UTC) produces boundaries
      # hours apart -- and adjacent months created under different zones overlap
      # or leave a gap. Pinning the offset makes the DDL deterministic.
      def utc_midnight(date)
        "#{date} 00:00:00+00"
      end

      def month_from_name(name)
        m = name.match(/_(\d{4})_(\d{2})\z/) or return nil
        Date.new(m[1].to_i, m[2].to_i, 1)
      end

      def year_from_name(name)
        m = name.match(/_(\d{4})\z/) or return nil
        m[1].to_i
      end

      # [lower, upper] the name claims, or nil if it claims neither a month nor a
      # year. Month is tried first: audit_events_2026_08 ends in _08, so it can
      # never be mistaken for a year.
      def expected_bounds(name)
        if (month = month_from_name(name))
          [month.to_time(:utc), (month >> 1).to_time(:utc)]
        elsif (year = year_from_name(name))
          [Time.utc(year), Time.utc(year + 1)]
        end
      end

      def parent_table_for(name)
        TABLES.find { |t| name.start_with?("#{t}_") } or
          raise Error, "#{name} does not belong to a known audit table"
      end

      def retired_name(table, name)
        name.sub(/\A#{Regexp.escape(table)}_/, "#{table}_#{RETIRED_INFIX}_")
      end

      def attached?(name, connection:)
        connection.select_value(<<~SQL).present?
          SELECT c.relname
          FROM   pg_class c
          JOIN   pg_inherits i ON i.inhrelid = c.oid
          WHERE  c.relname = #{connection.quote(name)}
        SQL
      end

      def exists?(name, connection:)
        # ::text because the regclass OID has no registered Active Record type,
        # which otherwise logs "unknown OID 2205" on every call.
        connection.select_value(
          "SELECT to_regclass(#{connection.quote("public.#{name}")})::text"
        ).present?
      end

      # Every DDL path here needs ACCESS EXCLUSIVE on a table the application is
      # actively writing to. Without a timeout, one long-running reader makes the
      # maintenance statement wait -- and because a pending ACCESS EXCLUSIVE
      # request blocks every lock request queued behind it, the audit write path
      # stalls for the whole wait. Failing after a few seconds and reporting it is
      # strictly better than a maintenance task that takes the application down.
      def with_lock_timeout(connection, timeout = AuditLog.config.maintenance_lock_timeout)
        previous = connection.select_value("SHOW lock_timeout")
        connection.execute("SET lock_timeout = #{connection.quote(timeout)}")
        yield
      ensure
        connection.execute("SET lock_timeout = #{connection.quote(previous)}") if previous
      end
    end
  end
end
