# frozen_string_literal: true

require "rails_helper"

# The drill-down is the one auditor query with no occurred_at predicate of its
# own: `WHERE request_id = ?` names the partition key nowhere, so the planner
# cannot eliminate a single partition and scans all of them -- 84 at a 7-year
# retention horizon, on a hot UI path, growing with the retention decision.
#
# RequestDrillDown supplies the missing bound from an event's own occurred_at
# where one is in hand, and otherwise from the UUIDv7 request_id itself. These
# examples pin down BOTH halves of that: that it prunes, and -- more important --
# that it does not change the answer. A bound that returns fewer rows than exist
# would be worse than the slow query it replaced.
RSpec.describe AuditLog::RequestDrillDown do
  def partitions_touched(relation, parent)
    ActiveRecord::Base.connection
      .select_values("EXPLAIN #{relation.to_sql}")
      .join("\n")
      .scan(/#{parent}_\d{4}_\d{2}|#{parent}_default/)
      .uniq
  end

  # A request written right now, so the id's embedded timestamp and the rows'
  # occurred_at agree the way they do in production. Emits a registered action so
  # there is a layer-2 row to anchor on as well as layer-1 rows to find.
  def a_request
    request_id = nil

    as_actor(create_user) do
      request_id = AuditLog::Current.request_id
      customer   = create_customer(name: "Drill Down Co")
      customer.update!(status: "active")
      AuditLog.notify("customer.updated", customer_id: customer.id, name: customer.name)
    end

    request_id
  end

  describe AuditLog::Context do
    it "decodes the mint instant out of a v7 id with no database access" do
      before = Time.now.utc
      id     = AuditLog::Context.new_request_id

      expect(AuditLog::Context.minted_at(id)).to be_within(5.seconds).of(before)
    end

    # The important negative case. In a v4 id those 48 bits are random, so
    # decoding one yields a plausible timestamp somewhere in the next half-million
    # years -- and a drill-down bounded by it would silently return nothing. Nil
    # means "no bound available", and the caller must degrade to a full scan.
    it "refuses a v4 id rather than inventing a timestamp from random bits" do
      expect(AuditLog::Context.minted_at(SecureRandom.uuid)).to be_nil
    end

    it "refuses anything that is not a uuid" do
      ["", "not-a-uuid", nil, "01a04514-320f-7edd-b792"].each do |bad|
        expect(AuditLog::Context.minted_at(bad)).to be_nil
      end
    end
  end

  describe "the bound does not change the answer" do
    it "returns exactly what the unbounded query returns, from an id alone" do
      rid = a_request
      dd  = described_class.new(rid)

      expect(dd.anchor_source).to eq(:request_id)
      expect(dd.changes.pluck(:id)).to eq(dd.unbounded.changes.pluck(:id))
      expect(dd.changes.count).to be_positive
    end

    it "returns exactly what the unbounded query returns, from an event anchor" do
      rid   = a_request
      event = AuditLog::Event.find_by!(request_id: rid)

      expect(event.drill_down.anchor_source).to eq(:event)
      expect(event.changes_in_request.pluck(:id))
        .to eq(described_class.new(rid).unbounded.changes.pluck(:id))
    end
  end

  describe "partition pruning" do
    it "prunes to fewer partitions than the unbounded query touches" do
      rid = a_request
      dd  = described_class.new(rid)

      bounded   = partitions_touched(dd.changes, "audit_changes")
      unbounded = partitions_touched(dd.unbounded.changes, "audit_changes")

      expect(bounded.size).to be < unbounded.size
      expect(unbounded).to include("audit_changes_default")
      expect(bounded).not_to include("audit_changes_default")
    end

    it "prunes audit_events too, which is why layer 2 stays partitioned" do
      dd = described_class.new(a_request)

      expect(partitions_touched(dd.events, "audit_events").size)
        .to be < partitions_touched(dd.unbounded.events, "audit_events").size
    end
  end

  # caused_by_request_id answers "what did this action set in motion?" -- the jobs
  # it enqueued, each of which got a FRESH request_id and points back here. It was
  # a metadata key until the promote migration, which made this screen's query an
  # unindexed sequential scan of every partition of audit_events.
  describe "the causal chain" do
    it "is a real column, not a metadata key" do
      expect(AuditLog::Event.column_names).to include("caused_by_request_id")
    end

    # Per the note in CLAUDE.md: assert the index DEFINITION from pg_indexes,
    # which is deterministic and is what actually regresses when someone edits the
    # install SQL -- not the plan's index choice, which a small test database
    # correctly declines to make.
    it "is indexed on every partition, partially and with occurred_at" do
      defs = ActiveRecord::Base.connection.select_values(<<~SQL)
        SELECT indexdef FROM pg_indexes
        WHERE tablename LIKE 'audit_events_%' AND indexdef LIKE '%caused_by_request_id%'
      SQL

      expect(defs).not_to be_empty
      defs.each do |d|
        expect(d).to include("caused_by_request_id, occurred_at DESC")
        expect(d).to include("WHERE (caused_by_request_id IS NOT NULL)")
      end
    end

    it "links two distinct units of work, and never a row to itself" do
      cause_id = a_request
      caused = as_actor(create_user) do
        AuditLog::Current.caused_by_request_id = cause_id
        customer = create_customer(name: "Effect Co")
        AuditLog.notify("customer.created", customer_id: customer.id, name: customer.name)
        AuditLog::Event.find_by!(request_id: AuditLog::Current.request_id)
      end

      expect(caused.caused_by_request_id).to eq(cause_id)
      expect(caused.caused_by_request_id).not_to eq(caused.request_id)

      found = described_class.new(cause_id).caused_events
      expect(found.map(&:request_id)).to include(caused.request_id)
    end

    it "prunes partitions instead of scanning all of them" do
      dd = described_class.new(a_request)

      bounded   = partitions_touched(dd.caused_events, "audit_events")
      unbounded = partitions_touched(dd.unbounded.caused_events, "audit_events")

      expect(bounded.size).to be < unbounded.size
      expect(bounded).not_to include("audit_events_default")
    end
  end

  describe "degrading safely" do
    it "runs unbounded when the id carries no timestamp" do
      dd = described_class.new(SecureRandom.uuid)

      expect(dd).not_to be_bounded
      expect(dd.anchor_source).to eq(:none)
      expect(dd.window).to be_nil
      expect(partitions_touched(dd.changes, "audit_changes")).to include("audit_changes_default")
    end

    it "runs unbounded when the caller opts out" do
      dd = described_class.new(a_request, bounded: false)

      expect(dd).not_to be_bounded
      expect(partitions_touched(dd.changes, "audit_changes")).to include("audit_changes_default")
    end

    it "describes which scope it searched, so a narrowed view cannot pass for a complete one" do
      expect(described_class.new(a_request).scope_description).to match(/within .* of when this id/)
      expect(described_class.new(SecureRandom.uuid).scope_description).to eq("across all retained history")
    end
  end
end
