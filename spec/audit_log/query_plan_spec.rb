# frozen_string_literal: true

require "rails_helper"

# A schema that stores the right data can still fail to ANSWER anything.
#
# These examples assert on the PLAN, not the result. Two different things are
# being checked, and they need different setups:
#
#   Partition pruning -- size-independent and the whole performance story. A
#   bounded date range must cause Postgres to skip every partition outside it.
#
#   Index availability -- on a table with a handful of rows the planner will
#   correctly prefer a sequential scan no matter how good the index is, so
#   asserting "Index Scan" on a test database asserts nothing. Disabling
#   seqscan for the EXPLAIN forces the planner to reveal whether a usable index
#   exists at all, which is the thing a regression would actually break.
RSpec.describe "query plans" do
  let(:range) { 7.days.ago..Time.current }

  def explain(relation, force_index: false)
    conn = ActiveRecord::Base.connection
    conn.execute("SET LOCAL enable_seqscan = off") if force_index
    conn.select_values("EXPLAIN #{relation.to_sql}").join("\n")
  ensure
    conn.execute("SET LOCAL enable_seqscan = on") if force_index
  end

  # Indexes on a partitioned parent are created on each partition under a
  # partition-local name (audit_changes_2026_09_actor_idx), so plans are matched
  # on the shared suffix rather than the parent's index name.
  def partitions_touched(plan, parent)
    plan.scan(/#{parent}_\d{4}_\d{2}|#{parent}_default/).uniq
  end

  describe "partition pruning" do
    it "touches only the partitions a bounded range covers" do
      plan = explain(AuditLog::Change.occurred_between(Time.zone.today.all_day))
      touched = partitions_touched(plan, "audit_changes")

      this_month = AuditLog::Partitions.partition_name("audit_changes", Date.current)
      expect(touched).to include(this_month)
      expect(touched).not_to include(
        AuditLog::Partitions.partition_name("audit_changes", Date.current >> 2)
      )
    end

    it "scans every partition when the range is unbounded -- which is why the UI requires one" do
      bounded   = partitions_touched(explain(AuditLog::Change.occurred_between(Time.zone.today.all_day)),
                                     "audit_changes")
      unbounded = partitions_touched(explain(AuditLog::Change.all), "audit_changes")

      expect(unbounded.size).to be > bounded.size
    end
  end

  # On a test database with a handful of rows, no amount of planner coaxing will
  # reliably make Postgres choose one specific index over another -- every plan
  # costs about the same. So index correctness is asserted where it is actually
  # deterministic: against the catalog. This is also the thing that regresses in
  # practice (someone edits the install SQL and drops an index), and it catches
  # that regardless of table size.
  describe "the indexes the auditor screens depend on" do
    def index_defs(table)
      ActiveRecord::Base.connection.select_rows(
        "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = $1",
        "SCHEMA", [table]
      ).to_h
    end

    it "indexes audit_changes for every canonical question" do
      defs = index_defs("audit_changes").values.join("\n")

      expect(defs).to match(/\(actor_type, actor_id, occurred_at DESC\)/)      # Q1
      expect(defs).to match(/\(record_type, record_id, occurred_at DESC\)/)    # Q2 one record
      expect(defs).to match(/\(record_type, occurred_at DESC\)/)               # Q2 whole class
      expect(defs).to match(/\(request_id\)/)                                  # drill-down
      expect(defs).to match(/\(occurred_at DESC\)/)                            # out-of-band review
    end

    it "indexes changed_columns with GIN, and does NOT put a GIN index on diff" do
      defs = index_defs("audit_changes").values.join("\n")

      expect(defs).to match(/USING gin \(changed_columns\)/)

      # A jsonb_path_ops GIN index does not support the `?` key-existence
      # operator, so a "which changes touched status" query against one silently
      # falls back to a sequential scan. changed_columns exists precisely so that
      # index is not needed.
      expect(defs).not_to match(/USING gin \(diff/)
    end

    it "indexes audit_events for the action report and the actor timeline" do
      defs = index_defs("audit_events").values.join("\n")

      expect(defs).to match(/\(action, occurred_at DESC\)/)                    # Q3
      expect(defs).to match(/\(actor_type, actor_id, occurred_at DESC\)/)      # Q1
      expect(defs).to match(/\(subject_type, subject_id, occurred_at DESC\)/)
      expect(defs).to match(/\(request_id\)/)
    end

    it "propagates every parent index down to each partition" do
      parent    = index_defs("audit_changes").size
      partition = index_defs(
        AuditLog::Partitions.partition_name("audit_changes", Date.current)
      ).size

      expect(partition).to eq(parent)
    end
  end

  describe "plan shape" do
    it "reaches audit rows by index rather than by scanning a partition" do
      plan = explain(AuditLog::Change.for_record("Order", 1).occurred_between(range),
                     force_index: true)

      expect(plan).to match(/Index Scan|Index Only Scan|Bitmap Index Scan/)
      expect(plan).not_to match(/Seq Scan/)
    end

    it "reaches the request drill-down by index" do
      plan = explain(AuditLog::Change.where(request_id: SecureRandom.uuid_v7), force_index: true)
      expect(plan).to match(/_request_id_idx/)
    end
  end
end
