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
  #
  # ---------------------------------------------------------------------------
  # EVERY CATALOG QUERY HERE IS SCOPED TO current_schema()
  #
  # Partitions are created unqualified, so they land beside the parent in
  # whatever schema `search_path` names -- and `current_schema()` is that schema.
  # In the overwhelmingly common single-schema application it is `public` and
  # this is a distinction without a difference. It is not one when a database
  # holds the same table name in several schemas, and the two ways to get it
  # wrong were both present here:
  #
  #   HARDCODING 'public' under-matches. `exists?` asked for
  #   `public.audit_changes_2026_08`, found it, and reported that the partition
  #   existed -- to a caller provisioning a DIFFERENT schema, which then
  #   provisioned nothing. The parent table sat there with no partitions and the
  #   first write to it failed with "no partition of relation ... found for row".
  #
  #   FILTERING ON relname ALONE over-matches. `attached?` and the inventory
  #   queries saw every schema's partitions at once, so one schema's healthy
  #   state answered questions asked about another's.
  #
  # Neither failure announces itself, which is why the scope is spelled on every
  # query rather than left to whichever ones seemed to need it.
  module Partitions
    TABLES = %w[audit_events audit_changes].freeze

    # Detached-but-kept partitions are renamed into this infix rather than left
    # under their original name, so that "expired, awaiting export" is a visible
    # state rather than an invisible one, and so `exists?` in create_month! can
    # never mistake a retired table for a live partition.
    RETIRED_INFIX = "retired"

    # Stamped as a table comment on a rollup's staging table and cleared when the
    # swap succeeds. It is what tells a later run that an existing
    # audit_events_2019 is our own debris from an interrupted rollup and not
    # somebody's manual backup -- the difference between a safe reset and
    # dropping a table this library did not create.
    ROLLUP_MARKER = "audit_log:rollup-in-progress"

    # Stamped on every partition this library retires, and the ONLY proof that a
    # table named like a retired partition actually is one.
    #
    # It does two jobs that a name cannot:
    #
    #   PROVENANCE. `audit_changes_retired_2019_01` is a name anybody can create,
    #   and a DBA taking a manual copy before a risky migration is the obvious
    #   way it happens. Dropping on a name match would destroy that copy while
    #   the operator believed they had made a backup. Same reasoning as
    #   ROLLUP_MARKER above: only the marker separates our debris from somebody's
    #   data.
    #
    #   THE DATE RANGE. DETACH clears `relpartbound`, so retiring a partition
    #   destroys the authoritative record of what period it covers -- and the
    #   name is a known unreliable substitute, which is precisely what
    #   `misaligned_bounds` exists to catch. The bound is in hand at retire time,
    #   so it is recorded rather than re-derived later from the one artifact with
    #   a history of lying.
    #
    # The payload is the EXCLUSIVE upper bound, which is what the partition
    # actually held, and what `drop_retired`'s BEFORE filter compares against --
    # keying on the upper bound for the same reason `expired_partitions` does.
    RETIRED_MARKER = "audit_log:retired"

    def self.retired_comment(upper)
      "#{RETIRED_MARKER} #{{upper: upper.utc.iso8601, retired_at: Time.now.utc.iso8601}.to_json}"
    end

    # Stamped on a partition once it has been VACUUM FREEZEd, so the next run can
    # tell what is already done.
    #
    # WITHOUT IT, FREEZING CANNOT BE AUTOMATIC. `freeze_closed!` used to re-freeze
    # every closed partition on every call: unbounded work that grows with the
    # retention horizon, and an ANALYZE re-sampling statistics that cannot have
    # changed on an immutable partition. That is what forced the operator to
    # decide *when* to run it. Marked, the work is bounded to what is newly
    # closed -- usually nothing, once a month exactly one partition per table --
    # so the daily task can simply do it.
    #
    # A live partition can carry no other marker: RETIRED_MARKER goes on detached
    # tables and ROLLUP_MARKER on staging tables, neither of which is an attached
    # partition. So there is nothing here to clobber.
    FROZEN_MARKER = "audit_log:frozen"

    # Session-level advisory lock serialising drain / rollup / retire against
    # each other. See `with_maintenance_lock`.
    MAINTENANCE_LOCK_KEY = 0x4155_4449_5401 # "AUDIT" + 01

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
        with_maintenance_lock(connection) do
          TABLES.index_with { |table| drain_table_default!(table, connection: connection) }
        end
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

      # DETACH everything past the retention horizon. It never drops.
      #
      # There is deliberately no option here. Retention decides WHAT IS PAST THE
      # HORIZON; disposal decides what happens to it, and they are separate
      # decisions made by different people at different times. Folding them into
      # one config attribute meant a single line in an initializer could turn a
      # scheduled task into one that destroys audit data -- and a safe default is
      # weaker than an absent option, because a default can be flipped.
      #
      # So the worst this can do is detach too much, which one ATTACH undoes.
      # Dropping lives in `audit_log:partitions:drop_retired`, where somebody has
      # to type it.
      def retire!(connection: ActiveRecord::Base.connection,
                  retention: AuditLog.config.retention,
                  &block)
        with_maintenance_lock(connection) do
          expired_partitions(connection: connection, retention: retention).map do |bound|
            retire_partition!(bound, connection: connection, &block)
          end
        end
      end

      # Detached-but-kept partitions still occupying disk. Anything here is
      # waiting on an export-and-drop decision.
      #
      # MARKED ONES ONLY. The name is not proof: `audit_changes_retired_2019_01`
      # is a name anybody can create, and a manual copy taken before a risky
      # migration is the obvious way it happens. Every task that EXPORTS or DROPS
      # works from this list, so the marker is the boundary of what this library
      # considers its own -- see RETIRED_MARKER.
      #
      # `upper` comes from the marker rather than from the name, and is what
      # `drop_retired`'s BEFORE filter compares. A row whose marker will not parse
      # gets `upper: nil` and is excluded from every date-bounded operation
      # rather than guessed at.
      def retired_partitions(connection: ActiveRecord::Base.connection)
        connection.select_all(<<~SQL).to_a.map do |r|
          SELECT c.relname AS name,
                 pg_total_relation_size(c.oid) AS bytes,
                 obj_description(c.oid, 'pg_class') AS comment
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  n.nspname = current_schema()
            AND  c.relkind = 'r'
            -- Regex, not LIKE: `_` is a LIKE wildcard, so
            -- 'audit_events_retired_%' also matches audit_eventsXretiredY2019.
            AND  c.relname ~ '^(audit_events|audit_changes)_#{RETIRED_INFIX}_'
            AND  obj_description(c.oid, 'pg_class') LIKE #{connection.quote("#{RETIRED_MARKER} %")}
          ORDER  BY c.relname
        SQL
          { name: r["name"], bytes: r["bytes"].to_i, upper: parse_retired_upper(r["comment"]) }
        end
      end

      # Tables that LOOK retired and carry no marker of ours.
      #
      # Reported rather than silently skipped, for the reason orphaned_rollups is
      # reported: an invisible cost is one nobody reclaims. Three things it can
      # be, and the operator wants to know about all of them -- somebody's manual
      # copy that we correctly refused to touch, a partition retired by a version
      # of this library that predates the marker, or one whose comment was lost.
      # Left alone by every task here; reclaiming the disk is a manual DROP.
      def unmarked_retired(connection: ActiveRecord::Base.connection)
        connection.select_all(<<~SQL).to_a.map { |r| { name: r["name"], bytes: r["bytes"].to_i } }
          SELECT c.relname AS name, pg_total_relation_size(c.oid) AS bytes
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  n.nspname = current_schema()
            AND  c.relkind = 'r'
            AND  c.relname ~ '^(audit_events|audit_changes)_#{RETIRED_INFIX}_'
            AND  (obj_description(c.oid, 'pg_class') IS NULL
                  OR obj_description(c.oid, 'pg_class') NOT LIKE #{connection.quote("#{RETIRED_MARKER} %")})
          ORDER  BY c.relname
        SQL
      end

      # Staging tables left behind by a rollup that failed after the copy but
      # before the swap. They are not partitions, so `list` does not show them and
      # no query touches them -- but each holds a full year of audit data and the
      # disk that goes with it. Reported for the same reason retired partitions
      # are: an invisible cost is one nobody reclaims.
      def orphaned_rollups(connection: ActiveRecord::Base.connection)
        connection.select_all(<<~SQL).to_a.map { |r| { name: r["name"], bytes: r["bytes"].to_i } }
          SELECT c.relname AS name, pg_total_relation_size(c.oid) AS bytes
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  n.nspname = current_schema()
            AND  c.relkind = 'r'
            AND  obj_description(c.oid, 'pg_class') = #{connection.quote(ROLLUP_MARKER)}
            AND  NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = c.oid)
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
          rollup_year!(candidate[:table], candidate[:year], connection: connection).tap do |r|
            yield r if r && block_given?
          end
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
        with_maintenance_lock(connection) { rollup_year(table, year, connection) }
      end

      private def rollup_year(table, year, connection)
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

        watermark = rollup_watermark(table, lo_lit, hi_lit, connection: connection)

        # ---- phase 1: build and fill, holding no lock on the parent ----------
        # An unattached table under the target name is either our own debris from
        # an interrupted run -- which holds nothing the parent does not, so
        # recreating is the safe reset -- or something this library did not
        # create. Only the marker distinguishes them, and dropping the second kind
        # would destroy data. `DROP TABLE IF EXISTS` cannot tell the difference,
        # so it is not used here.
        if exists?(target, connection: connection)
          unless rollup_debris?(target, connection: connection)
            raise Error, "#{target} already exists and carries no rollup marker, so it was not " \
                         "left behind by this library. Inspect and remove it before retrying."
          end
          connection.execute("DROP TABLE #{connection.quote_table_name(target)}")
        end

        # INCLUDING ALL carries the indexes, so ATTACH matches them against the
        # parent's partitioned indexes instead of rebuilding them under the lock.
        connection.execute(<<~SQL)
          CREATE TABLE #{connection.quote_table_name(target)}
          (LIKE #{connection.quote_table_name(table)} INCLUDING ALL)
        SQL
        connection.execute(
          "COMMENT ON TABLE #{connection.quote_table_name(target)} IS #{connection.quote(ROLLUP_MARKER)}"
        )
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
            connection.execute("COMMENT ON TABLE #{connection.quote_table_name(target)} IS NULL")

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
      # VACUUM FREEZE every closed partition that has not been frozen already.
      #
      # "Closed" means its month is over, so no ordinary write can reach it --
      # `occurred_at` is clock_timestamp(), which only ever moves forward. An
      # insert-only partition that is never frozen deliberately gets frozen
      # eventually by an anti-wraparound vacuum, which picks its own moment and
      # picks it on the largest table in the database.
      #
      # BOUNDED BY THE MARKER, which is what lets the daily task call this. On
      # most days nothing is newly closed and this is two catalog queries; on the
      # first run of a month it freezes exactly one partition per table.
      #
      # VACUUM first, mark second. The reverse would skip a partition forever if
      # the VACUUM failed after the comment committed; this way a failure merely
      # means it is retried tomorrow.
      def freeze_closed!(connection: ActiveRecord::Base.connection, force: false)
        cutoff = current_month.to_time(:utc)
        done   = force ? [] : frozen_partitions(connection: connection)

        partition_bounds(connection: connection)
          .select { |b| b[:upper] <= cutoff }
          .reject { |b| done.include?(b[:name]) }
          .map do |b|
            connection.execute("VACUUM (FREEZE, ANALYZE) #{connection.quote_table_name(b[:name])}")
            mark_frozen!(b[:name], connection: connection)
            b[:name]
          end
      end

      def frozen_partitions(connection: ActiveRecord::Base.connection)
        connection.select_values(<<~SQL)
          SELECT c.relname
          FROM   pg_class c
          JOIN   pg_inherits i ON i.inhrelid = c.oid
          JOIN   pg_class p ON p.oid = i.inhparent
          JOIN   pg_namespace n ON n.oid = p.relnamespace
          WHERE  p.relname IN ('audit_events', 'audit_changes')
            AND  n.nspname = current_schema()
            AND  obj_description(c.oid, 'pg_class') = #{connection.quote(FROZEN_MARKER)}
        SQL
      end

      def mark_frozen!(name, connection: ActiveRecord::Base.connection)
        connection.execute(
          "COMMENT ON TABLE #{connection.quote_table_name(name)} IS #{connection.quote(FROZEN_MARKER)}"
        )
      end

      # Clearing the marker is how a partition becomes freezable again.
      #
      # AuditLog::Redaction is what needs this. It issues UPDATE against the
      # PARENT table, so it reaches every attached partition including closed,
      # frozen ones, and dirties pages there. Left marked, such a partition would
      # never be frozen again and the anti-wraparound vacuum the freeze exists to
      # pre-empt would arrive anyway -- on a table everybody believed was handled.
      #
      # Redaction cannot know which partitions it touched (it filters on
      # record_type/record_id, not on time), so it clears every marker and lets
      # the daily task re-freeze. Erasure requests are rare; a re-freeze is not.
      def clear_frozen_marker!(names, connection: ActiveRecord::Base.connection)
        Array(names).each do |name|
          connection.execute("COMMENT ON TABLE #{connection.quote_table_name(name)} IS NULL")
        end
      end

      # ------------------------------------------------------------ inventory
      def list(connection: ActiveRecord::Base.connection)
        connection.select_values(<<~SQL)
          SELECT c.relname
          FROM   pg_class c
          JOIN   pg_inherits i ON i.inhrelid = c.oid
          JOIN   pg_class p ON p.oid = i.inhparent
          JOIN   pg_namespace n ON n.oid = p.relnamespace
          WHERE  p.relname IN ('audit_events', 'audit_changes')
            AND  n.nspname = current_schema()
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
          JOIN   pg_namespace n ON n.oid = p.relnamespace
          WHERE  p.relname IN ('audit_events', 'audit_changes')
            AND  n.nspname = current_schema()
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

      # The id watermark guarding the rollup swap. Private and separate so the
      # guard itself is reachable from a test -- it is the single piece of logic
      # here whose failure mode is silent data loss, and "I reasoned about it"
      # is not the same as "it fires".
      def rollup_watermark(table, lo_lit, hi_lit, connection:)
        connection.select_value(<<~SQL).to_i
          SELECT coalesce(max(id), 0) FROM #{connection.quote_table_name(table)}
          WHERE occurred_at >= #{lo_lit} AND occurred_at < #{hi_lit}
        SQL
      end

      def rollup_debris?(name, connection:)
        connection.select_value(<<~SQL).present?
          SELECT 1 FROM pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  c.relname = #{connection.quote(name)}
            AND  n.nspname = current_schema()
            AND  obj_description(c.oid, 'pg_class') = #{connection.quote(ROLLUP_MARKER)}
            AND  NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = c.oid)
        SQL
      end

      # The three maintenance operations must not overlap each other.
      #
      # Not a style preference -- it closes a hole in rollup_year!'s watermark
      # guard. drain_default! reinserts relocated rows under their ORIGINAL ids,
      # which are by definition below a watermark taken later, so a drain that
      # lands a row in a monthly partition midway through a rollup would slip past
      # `id > watermark` and be dropped with that partition. Phase 1 of a rollup
      # holds no lock on the parent, so the interleaving is possible. Serialising
      # the operations removes it, and incidentally stops two rollups or a
      # rollup and a retire racing.
      #
      # try_ rather than a blocking acquire: a second maintenance run should say
      # so immediately, not queue behind an hour-long rewrite.
      #
      # Advisory locks are re-entrant within a session, so this serialises
      # SESSIONS, not calls -- which is the case that matters (two rake tasks, a
      # cron overlapping a console). One session calling two of these in sequence
      # is unaffected, and that is deliberate.
      def with_maintenance_lock(connection)
        # `uncached` is load-bearing, not defensive. pg_try_advisory_lock is a
        # SELECT with a side effect, so ActiveRecord's query cache treats it as an
        # ordinary read: acquire, release, acquire again within one request or job
        # and the second acquire is served FROM THE CACHE as `true` while the
        # session holds no lock at all. Verified -- pg_locks reports zero. That
        # would leave this method reporting mutual exclusion it is not providing,
        # which is worse than not having it. Everything else in this module
        # mutates through `execute`, which does clear the cache.
        connection.uncached do
          unless connection.select_value("SELECT pg_try_advisory_lock(#{MAINTENANCE_LOCK_KEY})")
            raise Error, "another AuditLog::Partitions maintenance operation is already running " \
                         "on this database"
          end

          begin
            yield
          ensure
            # Inside the begin, so a failure to ACQUIRE does not fall through to
            # releasing a lock this session does not hold -- which Postgres answers
            # with a warning and a false, quietly hiding the real error.
            connection.select_value("SELECT pg_advisory_unlock(#{MAINTENANCE_LOCK_KEY})")
          end
        end
      end

      def retire_partition!(bound, connection:)
        name    = bound[:name]
        table   = parent_table_for(name)
        retired = retired_name(table, name)

        if exists?(retired, connection: connection)
          raise Error, "#{retired} already exists; #{name} was retired once before and " \
                       "recreated. Export and drop the old one first."
        end

        connection.transaction do
          connection.execute(
            "ALTER TABLE #{connection.quote_table_name(table)} " \
            "DETACH PARTITION #{connection.quote_table_name(name)}"
          )
          connection.execute(
            "ALTER TABLE #{connection.quote_table_name(name)} " \
            "RENAME TO #{connection.quote_table_name(retired)}"
          )
          # Inside the same transaction as the detach and rename: a partition
          # that is detached but unmarked is one this library can no longer
          # manage, so the three facts commit together or not at all.
          connection.execute(
            "COMMENT ON TABLE #{connection.quote_table_name(retired)} IS " \
            "#{connection.quote(retired_comment(bound[:upper]))}"
          )
        end

        # Yielded as each one commits, not collected and handed back at the end:
        # every partition is its own transaction, so a failure on the fifth leaves
        # four already retired, and a caller that only sees the return value sees
        # nothing at all about those four.
        bound.merge(retired_as: retired).tap { |r| yield r if block_given? }
      end

      def drain_table_default!(table, connection:)
        default = "#{table}_default"
        return { moved: 0, created: [] } unless exists?(default, connection: connection)

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
            next { moved: 0, created: [] } if months.empty?

            staging = "_audit_log_drain_#{table}"
            connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name(staging)}")
            connection.execute(<<~SQL)
              CREATE TEMP TABLE #{connection.quote_table_name(staging)}
              (LIKE #{connection.quote_table_name(table)}) ON COMMIT DROP
            SQL

            # `execute`, not select_value: this SELECT deletes rows. Running a
            # data-modifying statement through the query-cache path would both
            # cache it and skip the invalidation that every other write here
            # performs, so a later overflow_count could report rows that are gone.
            connection.execute(<<~SQL)
              WITH moved AS (DELETE FROM #{connection.quote_table_name(default)} RETURNING *)
              INSERT INTO #{connection.quote_table_name(staging)} SELECT * FROM moved
            SQL
            moved = connection.select_value(
              "SELECT count(*) FROM #{connection.quote_table_name(staging)}"
            ).to_i

            # A month already inside a yearly partition needs no monthly one, and
            # creating an overlapping partition would fail.
            covered = partition_bounds(connection: connection).select { |b| b[:name].start_with?("#{table}_") }
            created = months.reject { |month|
              start = month.to_time(:utc)
              covered.any? { |b| b[:lower] <= start && start < b[:upper] }
            }.filter_map { |month| create_month!(table, month, connection: connection) }

            connection.execute(<<~SQL)
              INSERT INTO #{connection.quote_table_name(table)}
              SELECT * FROM #{connection.quote_table_name(staging)}
            SQL

            # No frozen marker to clear here, and that is worth stating because it
            # looks like an omission. A row reaches the default partition ONLY
            # when nothing covers its month -- Postgres rejects an insert into the
            # default whose range another partition already claims -- so the
            # targets of a drain are always partitions it created a moment ago,
            # which are new and therefore unfrozen. The interaction that DOES
            # dirty a frozen partition is AuditLog::Redaction; see FROZEN_MARKER.
            { moved: moved, created: created }
          end
        end
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

      # nil rather than a guess when the marker is malformed: a date-bounded DROP
      # that cannot date a partition must skip it, not assume.
      def parse_retired_upper(comment)
        payload = comment.to_s.sub(/\A#{Regexp.escape(RETIRED_MARKER)} /, "")
        Time.iso8601(JSON.parse(payload).fetch("upper")).utc
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError
        nil
      end

      def retired_name(table, name)
        name.sub(/\A#{Regexp.escape(table)}_/, "#{table}_#{RETIRED_INFIX}_")
      end

      def attached?(name, connection:)
        connection.select_value(<<~SQL).present?
          SELECT c.relname
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          JOIN   pg_inherits i ON i.inhrelid = c.oid
          WHERE  c.relname = #{connection.quote(name)}
            AND  n.nspname = current_schema()
        SQL
      end

      def exists?(name, connection:)
        # ::text because the regclass OID has no registered Active Record type,
        # which otherwise logs "unknown OID 2205" on every call.
        connection.select_value(
          "SELECT to_regclass(#{connection.quote(name)})::text"
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
