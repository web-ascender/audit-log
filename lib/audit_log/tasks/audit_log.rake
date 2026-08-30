# frozen_string_literal: true

# Reported rather than silently skipped, for the reason orphaned_rollups is: an
# invisible cost is one nobody reclaims. A table that LOOKS retired and carries no
# marker of ours is either somebody's manual copy that we correctly refused to
# touch, or a partition this library can no longer manage -- and in both cases the
# disk it holds will never be freed by anything here.
def report_unmarked_retired
  AuditLog::Partitions.unmarked_retired.each do |r|
    warn "NOTE: #{r[:name]} looks retired but carries no #{AuditLog::Partitions::RETIRED_MARKER} " \
         "marker, so nothing here will export or drop it. " \
         "#{ActiveSupport::NumberHelper.number_to_human_size(r[:bytes])}. " \
         "Either this library did not retire it, or its comment was lost. Drop it by hand if it is yours."
  end
end

# A date-bounded drop skips what it cannot date rather than guessing, so say
# which ones -- otherwise BEFORE= appears to have simply missed them.
def report_undateable(before)
  undateable = AuditLog::Partitions.retired_partitions.reject { |r| r[:upper] }
  undateable.each do |r|
    warn "NOTE: #{r[:name]} has an unreadable retirement marker, so BEFORE=#{before.to_date} " \
         "skipped it. Drop it without BEFORE, or by hand."
  end
end

namespace :audit_log do
  desc "Create missing monthly partitions and report any default-partition overflow"
  task partitions: :environment do
    created = AuditLog::Partitions.ensure!
    puts created.any? ? "Created: #{created.join(', ')}" : "All partitions present."

    overflow = AuditLog::Partitions.overflow_count
    overflow.each do |table, count|
      next if count.zero?
      warn "WARNING: #{count} row(s) in #{table}_default -- a monthly partition was missing " \
           "when they were written. Attaching a partition covering their range will fail " \
           "until they are relocated."
    end

    # Every boundary must be UTC midnight, or adjacent months overlap (CREATE
    # fails) or leave a gap (rows land in the default partition, which then
    # blocks attaching the real one). A hit here means a partition was created
    # from a session whose TimeZone was not UTC.
    AuditLog::Partitions.misaligned_bounds.each do |b|
      warn "WARNING: #{b[:name]} is not UTC-aligned -- covers " \
           "#{b[:lower].iso8601} to #{b[:upper].iso8601}. Expect a gap or an " \
           "overlap at the month boundary; see AuditLog::Partitions."
    end

    AuditLog::Partitions.retired_partitions.each do |r|
      warn "NOTE: #{r[:name]} is detached and still occupying " \
           "#{ActiveSupport::NumberHelper.number_to_human_size(r[:bytes])}. Export it and drop it."
    end

    report_unmarked_retired

    # FREEZING RUNS HERE, and after the creation above rather than before it.
    #
    # Creation is the safety-critical half -- a missing future partition is a
    # write-path outage -- so it commits first, and a VACUUM that turns out slow
    # or fails cannot delay it.
    #
    # It is bounded by the frozen marker, so on most days this is two catalog
    # queries and no work; on the first run of a month it freezes exactly one
    # partition per table. That is what makes it safe to do daily, and it takes
    # the "when should I run freeze?" decision away from the operator entirely.
    frozen = AuditLog::Partitions.freeze_closed!
    puts "Froze: #{frozen.join(', ')}" if frozen.any?

    # Not partitions and not in `list`, so nothing else would ever mention them --
    # while each holds a full year of audit data.
    AuditLog::Partitions.orphaned_rollups.each do |r|
      warn "WARNING: #{r[:name]} is a staging table left by a rollup that did not finish, " \
           "occupying #{ActiveSupport::NumberHelper.number_to_human_size(r[:bytes])}. " \
           "Re-run `rake audit_log:rollup` to reclaim it."
    end
  end
  # ---------------------------------------------------------------------------
  # The partition lifecycle, nested so `rails -T audit_log:partitions` shows the
  # whole of it, and so the names read unambiguously in a crontab --
  # `partitions:drain_default` says which "default" it means, where a bare
  # `drain_default` does not.
  #
  # `audit_log:partitions` above KEEPS its name. Rake stores tasks by full name
  # string, so a task and a namespace may share one; the daily cron line, whose
  # failure is a write-path outage rather than a degraded report, never has to
  # change.
  namespace :partitions do
    desc "Move rows out of the default partition into the partitions that should hold them"
    task drain_default: :environment do
      # Takes ACCESS EXCLUSIVE on both audit tables -- see AuditLog::Partitions.
      result = AuditLog::Partitions.drain_default!
      result.each do |table, r|
        if r[:moved].zero?
          puts "#{table}_default: empty."
          next
        end

        created = r[:created].any? ? " into new partition(s) #{r[:created].join(", ")}" : ""
        puts "#{table}_default: moved #{r[:moved]} row(s)#{created}."

        # Rows landing in a frozen partition dirty it, so its marker was cleared
        # and the next daily run will freeze it again. Said out loud because it
        # explains why `audit_log:partitions` is about to do work tomorrow.
        if r[:unfrozen].present?
          puts "  unfrozen (will re-freeze on the next daily run): #{r[:unfrozen].join(", ")}"
        end
      end
    end

    desc "DETACH partitions past the retention horizon. Never drops. DRY_RUN=1 to preview"
    task retention: :environment do
      retention = AuditLog.config.retention
      if retention.nil?
        puts "Retention is disabled (AuditLog.config.retention is nil)."
        next
      end

      expired = AuditLog::Partitions.expired_partitions
      puts "Horizon: #{retention.inspect} -- anything ending before " \
           "#{(Time.now.utc - retention).iso8601} is expired."

      if expired.empty?
        puts "Nothing expired."
        next
      end

      if ENV["DRY_RUN"].present?
        expired.each { |b| puts "  would detach: #{b[:name]} (#{b[:lower].to_date} .. #{b[:upper].to_date})" }
        next
      end

      # Printed from the block, as each partition commits: every one is its own
      # transaction, so a failure partway through leaves the earlier ones already
      # retired, and the operator has to be told which.
      AuditLog::Partitions.retire! { |r| puts "  detached: #{r[:name]} -> #{r[:retired_as]}" }
      warn "Retired partitions still hold their data. Export and/or drop them; " \
           "`rake audit_log:partitions` lists them."
    end

    desc "Consolidate closed years of monthly partitions into yearly ones. DRY_RUN=1 to preview"
    task rollup: :environment do
      if AuditLog.config.rollup_after.nil?
        puts "Rollup is disabled (AuditLog.config.rollup_after is nil)."
        next
      end

      candidates = AuditLog::Partitions.rollup_candidates
      if candidates.empty?
        puts "No closed year is stored as monthly partitions."
        next
      end

      candidates.each do |c|
        puts "#{c[:table]} #{c[:year]}: #{c[:partitions].size} monthly partition(s) -> " \
             "#{AuditLog::Partitions.year_partition_name(c[:table], c[:year])}"
      end

      if ENV["DRY_RUN"].present?
        puts "DRY_RUN -- nothing changed."
        next
      end

      # Rewrites a full year of data and then takes ACCESS EXCLUSIVE for the swap.
      # Maintenance window, not a cron.
      AuditLog::Partitions.rollup! do |r|
        puts "  #{r[:name]}: #{r[:rows]} row(s), replaced #{r[:replaced].size} monthly partition(s)"
      end
    end

    desc "Export EVERY retired partition to DIR as gzipped CSV plus a manifest, verified"
    task export_retired: :environment do
      dir = ENV["DIR"] || AuditLog.config.archive_dir
      abort "DIR=/path/to/exports is required" if dir.blank?

      results = AuditLog::Archive.export_retired!(dir: dir)
      if results.empty?
        puts "Nothing retired to export."
        next
      end

      ok, failed = results.partition { |r| r[:ok] }
      ok.each do |r|
        puts "  exported: #{r[:partition]} -- #{r[:rows]} row(s), " \
             "#{ActiveSupport::NumberHelper.number_to_human_size(r[:bytes])}"
      end
      # Re-exported unconditionally, so the total is what THIS run cost -- the
      # number that tells an operator whether to be dropping more aggressively.
      puts "Total: #{ActiveSupport::NumberHelper.number_to_human_size(ok.sum { |r| r[:bytes] })} " \
           "across #{ok.size} partition(s) in #{dir}."

      failed.each { |r| warn "FAILED: #{r[:partition]} -- #{r[:error]}" }
      abort "#{failed.size} export(s) failed." if failed.any?
    end

    desc "DROP retired partitions WITHOUT checking for an export. [BEFORE=YYYY-MM-DD] [DRY_RUN=1]"
    task drop_retired: :environment do
      before = ENV["BEFORE"].presence&.then { |v| Time.parse(v).utc }
      scope  = AuditLog::Archive.droppable(before: before)

      if scope.empty?
        puts "Nothing to drop."
      elsif ENV["DRY_RUN"].present?
        scope.each do |r|
          puts "  would DROP: #{r[:name]} -- " \
               "#{ActiveSupport::NumberHelper.number_to_human_size(r[:bytes])} (unrecoverable)"
        end
      else
        # No export check on purpose. See AuditLog::Archive#drop_retired!.
        dropped = AuditLog::Archive.drop_retired!(before: before)
        dropped.each do |r|
          puts "  DROPPED: #{r[:name]} -- " \
               "#{ActiveSupport::NumberHelper.number_to_human_size(r[:bytes])}"
        end
        puts "Reclaimed #{ActiveSupport::NumberHelper.number_to_human_size(dropped.sum { |r| r[:bytes] })}."
      end

      report_unmarked_retired
      report_undateable(before) if before
    end

    desc "Export retired partitions, verify, then DROP only what verified. [BEFORE=YYYY-MM-DD]"
    task export_and_drop_retired: :environment do
      dir = ENV["DIR"] || AuditLog.config.archive_dir
      abort "DIR=/path/to/exports is required" if dir.blank?

      before = ENV["BEFORE"].presence&.then { |v| Time.parse(v).utc }

      exported = AuditLog::Archive.export_retired!(dir: dir)
      exported.reject { |r| r[:ok] }.each { |r| warn "FAILED to export: #{r[:partition]} -- #{r[:error]}" }

      results = AuditLog::Archive.drop_exported!(dir: dir, before: before)
      if results.empty?
        puts "Nothing to drop."
      else
        results.each do |r|
          if r[:dropped]
            puts "  DROPPED: #{r[:name]} -- " \
                 "#{ActiveSupport::NumberHelper.number_to_human_size(r[:bytes])} (export verified)"
          else
            warn "  KEPT: #{r[:name]} -- #{r[:error]}"
          end
        end
      end

      report_unmarked_retired
      report_undateable(before) if before
    end

    desc "VACUUM FREEZE closed partitions. Runs in audit_log:partitions already. FORCE=1 to redo all"
    task freeze: :environment do
      # A manual catch-up. The daily task does this, so reaching for it means
      # either the daily task has not run, or a marker is wrong and FORCE=1 is
      # the way to redo work that was already recorded as done.
      frozen = AuditLog::Partitions.freeze_closed!(force: ENV["FORCE"].present?)
      puts frozen.any? ? "Froze: #{frozen.join(', ')}" : "Nothing to freeze -- every closed partition is already frozen."
    end
  end

  desc "Redact a record's values from the audit log. RECORD=Type:id REASON=DSR-1182 [FIELDS=a,b] [DRY_RUN=1]"
  task redact: :environment do
    record = ENV["RECORD"].to_s.split(":")
    reason = ENV["REASON"]
    abort "RECORD=Type:id is required, e.g. RECORD=Customer:42" unless record.size == 2
    abort "REASON is required -- a redaction without a written authorization is not auditable." if reason.blank?

    type, id = record
    # FIELDS, not COLUMNS: COLUMNS is a reserved shell variable holding the
    # terminal width, so `COLUMNS=email rake ...` silently arrives as the
    # terminal width instead -- which then matches no column and redacts nothing
    # while reporting success.
    columns  = ENV["FIELDS"].to_s.split(",").map(&:strip).presence

    preview = AuditLog::Redaction.preview(record_type: type, record_id: id)
    puts "#{type} ##{id}: #{preview[:changes]} change row(s), #{preview[:events]} event row(s)."
    puts "Columns recorded: #{preview[:columns].join(", ").presence || "none"}"
    puts "Would redact: #{columns&.join(", ") || "every recorded value"}"

    if ENV["DRY_RUN"].present?
      puts "DRY_RUN -- nothing changed."
      next
    end

    # Irreversible by design: the values are overwritten in place, which is the
    # point of an erasure request. Structure survives, values do not.
    result = AuditLog::Redaction.redact_record!(
      record_type: type, record_id: id, columns: columns, reason: reason
    )
    puts "Redacted #{result[:changes]} change row(s) and #{result[:events]} event row(s)."
    puts "Marker: #{result[:marker]}"
    puts "The redaction is itself logged as `audit.redaction`."
  end

  desc "Report correlated changes with no registered action (completeness reconciler)"
  task reconcile: :environment do
    rows = AuditLog::Reconciler.new.uncovered_requests
    if rows.empty?
      puts "OK: every correlated change in the last day is covered by a registered action."
    else
      puts "#{rows.size} uncovered request(s):"
      rows.each do |r|
        puts format("  %s  %s  %d change(s)  %s",
                    r.request_id, r.occurred_at, r.change_count, r.record_types.join(","))
      end
      exit 1
    end
  end

  desc "List tables in the primary database that have no audit trigger"
  task coverage: :environment do
    # Same AuditLog::Coverage the shared example in audit_log/rspec uses, so the
    # rake task and the spec cannot disagree about what counts as covered.
    coverage = AuditLog::Coverage.new

    puts coverage.report
    exit 1 unless coverage.ok?
  end
end

namespace :audit_log do
  BENCHMARK_TAG = "benchmark@example.invalid"

  desc "Generate audit volume and EXPLAIN the canonical auditor queries (ROWS=100000)"
  task benchmark: :environment do
    abort "Refusing to run in production." if Rails.env.production?

    rows = Integer(ENV.fetch("ROWS", 100_000))
    conn = ActiveRecord::Base.connection

    # Only months that already have a partition, so the generated rows exercise
    # the real partitions instead of piling into the default one.
    months = AuditLog::Partitions.list
      .grep(/\Aaudit_changes_(\d{4})_(\d{2})\z/) { [$1.to_i, $2.to_i] }
      .map { |y, m| Date.new(y, m, 1) }
      .select { |d| d <= Time.now.utc.to_date }   # UTC: boundaries are UTC
      .sort
    abort "No past-or-current partitions to fill." if months.empty?

    puts "Generating #{rows} audit_changes rows across #{months.size} partition(s): " \
         "#{months.map { |m| m.strftime('%Y-%m') }.join(', ')}"
    puts "NOTE: this writes synthetic rows into the audit tables. Run it against a scratch"
    puts "      database, or clean up afterwards with: rake audit_log:benchmark_cleanup"
    puts

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Written directly rather than through the trigger: the point is to measure
    # the READ paths at volume, and this many real writes would take minutes.
    #
    # changed_columns is deliberately VARIED. Uniform values would make the field
    # filter 100%-selective, at which point a sequential scan is the correct plan
    # and the benchmark would "fail" while measuring nothing.
    conn.execute(<<~SQL)
      INSERT INTO audit_changes
        (occurred_at, request_id, record_type, record_id, operation, diff,
         changed_columns, actor_type, actor_id, actor_label)
      SELECT
        (ARRAY[#{months.map { |m| conn.quote(m.to_s) }.join(",")}]::date[])[1 + floor(random() * #{months.size})]
          + (random() * interval '27 days'),
        gen_random_uuid(),
        (ARRAY['Order','LineItem','Product','Customer','Shipment'])[1 + floor(random() * 5)],
        floor(random() * 50000)::bigint,
        (ARRAY['I','U','D'])[1 + floor(random() * 3)],
        jsonb_build_object('total_cents', jsonb_build_array(100, 200)),
        CASE floor(random() * 8)::int
          WHEN 0 THEN ARRAY['status']
          WHEN 1 THEN ARRAY['status','total_cents']
          WHEN 2 THEN ARRAY['notes']
          WHEN 3 THEN ARRAY['quantity','unit_price_cents']
          WHEN 4 THEN ARRAY['price_cents']
          WHEN 5 THEN ARRAY['email','phone']
          WHEN 6 THEN ARRAY['carrier','tracking_number']
          ELSE ARRAY['name']
        END,
        'User',
        1 + floor(random() * 200)::bigint,
        'Load Test User ' || (1 + floor(random() * 200))::text || ' <#{BENCHMARK_TAG}>'
      FROM generate_series(1, #{rows})
    SQL

    conn.execute("ANALYZE audit_changes")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    puts "  inserted in #{elapsed.round(1)}s"

    overflow = AuditLog::Partitions.overflow_count["audit_changes"]
    warn "  WARNING: #{overflow} row(s) landed in audit_changes_default" if overflow.positive?
    puts

    range     = (months.last..(months.last + 27.days))
    sample_id = conn.select_value("SELECT request_id FROM audit_changes LIMIT 1")

    # Driven through the LIBRARY'S OWN query objects, not hand-rolled relations.
    # An earlier version of this task omitted the ORDER BY that RecordHistory
    # actually applies, and consequently measured a plan the application never
    # runs -- reporting a sequential scan for a query that in reality uses
    # (record_type, occurred_at DESC) and returns in under 2ms.
    queries = {
      "Q1  actor activity -- events (bounded)" =>
        AuditLog::ActorActivity.new(actor_type: "User", actor_id: 42, range: range).events.limit(50),
      "Q1  actor activity -- changes (bounded)" =>
        AuditLog::ActorActivity.new(actor_type: "User", actor_id: 42, range: range)
          .changes(operations: %w[U D]).limit(50),
      "Q2  one record (unbounded, as the UI allows)" =>
        AuditLog::RecordHistory.new(record_type: "Order", record_id: 1234).changes,
      "Q2  whole class (bounded)" =>
        AuditLog::RecordHistory.new(record_type: "Order", range: range).changes(limit: 50),
      "Q2  field filter (bounded, GIN)" =>
        AuditLog::RecordHistory.new(record_type: "Order", range: range, columns: ["status"])
          .changes(limit: 50),
      "Q3  action report (bounded)" =>
        AuditLog::ActionReport.new(action: "order.submitted", range: range).events.limit(50),
      "    drill-down by request_id" =>
        AuditLog::Change.where(request_id: sample_id).order(:occurred_at, :id)
    }

    # A sequential scan is only a finding on a partition big enough for it to
    # cost anything. On a nearly-empty future partition it is the correct plan,
    # and flagging it would train people to ignore this output.
    big = conn.select_rows(<<~SQL).to_h
      SELECT c.relname, pg_total_relation_size(c.oid)
      FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace n ON n.oid = p.relnamespace
      WHERE p.relname = 'audit_changes' AND n.nspname = current_schema()
    SQL
    threshold = 1024 * 1024

    queries.each do |label, relation|
      plan  = conn.select_values("EXPLAIN (ANALYZE, BUFFERS) #{relation.to_sql}")
      text  = plan.join("\n")
      parts = text.scan(/audit_changes_\d{4}_\d{2}|audit_changes_default/).uniq.sort

      seq_on = text.lines.grep(/Seq Scan on (\S+)/) { $1 }.uniq
      bad    = seq_on.select { |t| big.fetch(t, 0) > threshold }

      puts label
      puts "  partitions touched : #{parts.size}#{" -- #{parts.join(', ')}" if parts.any?}"
      puts "  seq scan           : " + if bad.any?
        "PROBLEM on #{bad.join(', ')} (>1MB)"
      elsif seq_on.any?
        "only on near-empty partitions (fine)"
      else
        "none"
      end
      puts "  #{plan.grep(/Execution Time|Planning Time/).map(&:strip).join('   ')}"
      puts
    end

    puts "Storage:"
    puts conn.select_values(<<~SQL).join("\n")
      SELECT '  ' || c.relname || ': ' || pg_size_pretty(pg_total_relation_size(c.oid))
      FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace n ON n.oid = p.relnamespace
      WHERE p.relname IN ('audit_changes', 'audit_events')
        AND n.nspname = current_schema()
      ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 10
    SQL
    puts

    # pg_total_relation_size on a PARTITIONED PARENT returns only the parent's own
    # (empty) size, so the partitions have to be summed explicitly.
    puts "  bytes per audit_changes row: " + conn.select_value(<<~SQL).to_s
      SELECT round(
        (SELECT sum(pg_total_relation_size(c.oid))
         FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
         JOIN pg_class p ON p.oid = i.inhparent
         JOIN pg_namespace n ON n.oid = p.relnamespace
         WHERE p.relname = 'audit_changes' AND n.nspname = current_schema())::numeric
        / greatest((SELECT count(*) FROM audit_changes), 1), 1)
    SQL
  end

  desc "Delete the synthetic rows written by audit_log:benchmark"
  task benchmark_cleanup: :environment do
    abort "Refusing to run in production." if Rails.env.production?

    deleted = ActiveRecord::Base.connection.delete(
      "DELETE FROM audit_changes WHERE actor_label LIKE '%#{BENCHMARK_TAG}%'"
    )
    puts "Deleted #{deleted} synthetic row(s)."
  end
end
