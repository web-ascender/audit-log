# frozen_string_literal: true

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
  end

  desc "VACUUM FREEZE every closed partition"
  task freeze: :environment do
    frozen = AuditLog::Partitions.freeze_closed!
    puts frozen.any? ? "Froze: #{frozen.join(', ')}" : "Nothing to freeze."
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
    conn = ApplicationRecord.connection
    audited = conn.select_values(<<~SQL)
      SELECT c.relname FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      WHERE NOT t.tgisinternal AND t.tgname LIKE '%\\_audit'
    SQL

    # Partitions inherit their parent's triggers and cannot be attached
    # independently, so they are not candidates for auditing.
    partitions = conn.select_values(
      "SELECT c.relname FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid"
    )

    missing = conn.tables - audited - partitions - AuditLog.config.unaudited_tables.keys

    if missing.empty?
      puts "OK: every table is either audited or explicitly exempted."
    else
      puts "Untracked tables: #{missing.join(', ')}"
      exit 1
    end
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
      JOIN pg_class p ON p.oid = i.inhparent WHERE p.relname = 'audit_changes'
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
      WHERE p.relname IN ('audit_changes', 'audit_events')
      ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 10
    SQL
    puts

    # pg_total_relation_size on a PARTITIONED PARENT returns only the parent's own
    # (empty) size, so the partitions have to be summed explicitly.
    puts "  bytes per audit_changes row: " + conn.select_value(<<~SQL).to_s
      SELECT round(
        (SELECT sum(pg_total_relation_size(c.oid))
         FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
         JOIN pg_class p ON p.oid = i.inhparent WHERE p.relname = 'audit_changes')::numeric
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
