# frozen_string_literal: true

module AuditLog
  # Monthly range partitions on occurred_at for both audit tables.
  #
  # Partition pruning is the entire performance story for the auditor screens
  # (plan §11.0 Rule 1), and a missing FUTURE partition is a write-path outage --
  # every audited INSERT/UPDATE/DELETE in the application starts failing. So:
  #
  #   * `ensure!` provisions several months ahead and is safe to run repeatedly.
  #   * A DEFAULT partition is created as a backstop, and `overflow_count` reports
  #     rows that landed in it. See the note on `create_default!` for why that is
  #     a deliberate trade rather than an unambiguous win.
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
  module Partitions
    TABLES = %w[audit_events audit_changes].freeze

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
      # make that condition loud rather than latent. In a deployment with real
      # monitoring on the rotation job, dropping this is defensible.
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

      # Once a month closes its partition never changes again, so freezing it
      # deterministically beats waiting for an anti-wraparound vacuum to storm
      # through the largest table in the database months later. On PG 18 eager
      # freezing handles the current partition too; this still helps closed ones.
      def freeze_closed!(connection: ActiveRecord::Base.connection)
        cutoff = current_month
        list(connection: connection).filter_map do |name|
          month = month_from_name(name)
          next if month.nil? || month >= cutoff

          connection.execute("VACUUM (FREEZE, ANALYZE) #{connection.quote_table_name(name)}")
          name
        end
      end

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

      # The actual range each monthly partition covers, as Time objects in UTC.
      #
      # Read back out of pg_get_expr rather than recomputed from the name, so this
      # reports what Postgres will really route on. The rendered literal always
      # carries an explicit UTC offset, so the ::timestamptz cast round-trips
      # regardless of the session TimeZone doing the reading.
      def month_bounds(connection: ActiveRecord::Base.connection)
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

      # Any partition whose range is not exactly [UTC midnight, UTC midnight) on
      # the first of consecutive months. A non-empty result means someone created
      # a partition from a session whose TimeZone was not UTC -- by hand in psql,
      # or from a host app that overrides the connection timezone. Left alone it
      # produces a gap or an overlap at the month boundary. See the module comment.
      def misaligned_bounds(connection: ActiveRecord::Base.connection)
        month_bounds(connection: connection).reject do |b|
          # A name that does not parse as _YYYY_MM is not a monthly partition --
          # a yearly one produced by MERGE PARTITIONS has its own valid bounds.
          # Returning true here rejects it from the report rather than flagging it.
          expected = month_from_name(b[:name]) or next true
          b[:lower] == expected.to_time(:utc) && b[:upper] == (expected >> 1).to_time(:utc)
        end
      end

      def partition_name(table, month)
        format("%s_%04d_%02d", table, month.year, month.month)
      end

      private

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

      def exists?(name, connection:)
        # ::text because the regclass OID has no registered Active Record type,
        # which otherwise logs "unknown OID 2205" on every call.
        connection.select_value(
          "SELECT to_regclass(#{connection.quote("public.#{name}")})::text"
        ).present?
      end
    end
  end
end
