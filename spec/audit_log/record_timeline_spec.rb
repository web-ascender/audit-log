# frozen_string_literal: true

require "rails_helper"

# The narrative half of Q2 -- "what was DONE to this record, in words?"
#
# The property under test throughout is the one every spec in this suite is
# testing from a different angle: NOTHING GOES MISSING WITHOUT SAYING SO. Here
# that has a specific shape, because there are two populations and the honest
# thing is to keep them apart -- an action that named this record as its subject
# is a stronger claim than one that merely wrote to it, and only the second is
# capped.
RSpec.describe AuditLog::RecordTimeline do
  let(:staff) { create_user(name: "Raj Patel", role: "staff") }

  def timeline_for(record)
    described_class.new(record_type: record.class.name, record_id: record.id)
  end

  describe "#events" do
    it "returns the actions that named this record as their subject" do
      order = as_actor(staff) do
        o = Order.create!(customer: create_customer, created_by: staff,
                          line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
        AuditLog.notify("order.created", order_id: o.id, reference: o.reference,
                                         customer_name: o.customer.name, line_count: 1)
        o
      end
      as_actor(staff) { order.submit! }

      actions = timeline_for(order).events.map(&:action)
      expect(actions).to include("order.created", "order.submitted")
    end

    it "does not leak another record's actions" do
      customer = create_customer
      mine, theirs = as_actor(staff) do
        [1, 2].map do |_i|
          o = Order.create!(customer: customer, created_by: staff,
                            line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
          AuditLog.notify("order.created", order_id: o.id, reference: o.reference,
                                           customer_name: customer.name, line_count: 1)
          o
        end
      end

      subjects = timeline_for(mine).events.map { |e| e.metadata["order_id"] }
      expect(subjects.uniq).to eq([mine.id])
      expect(subjects).not_to include(theirs.id)
    end

    it "is unlimited and ordered, so the caller paginates it" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end

      # A limit baked below the controller is invisible to the screen rendering
      # it -- DESIGN 11.0 Rule 2, and the reason the fixed 200-row cap went away.
      expect(timeline_for(order).events.limit_value).to be_nil
      expect(timeline_for(order).events.to_sql).to match(/ORDER BY.*occurred_at.*DESC/i)
    end
  end

  describe "#correlated" do
    # price.bulk_adjusted is registered with NO subject: lambda, and writes
    # through update_all -- so it exists in audit_changes against each product
    # and in audit_events against nothing. This is precisely the action the
    # section is here to surface, and the one a subject-only screen would lose.
    let!(:product) { create_product(price_cents: 1_000) }

    def bulk_adjust!(percent: 10)
      as_actor(staff) do
        count = Product.where(id: product.id)
                       .update_all("price_cents = price_cents * #{(100 + percent) / 100.0}")
        AuditLog.notify("price.bulk_adjusted", percent: percent, count: count)
      end
    end

    it "finds an action that touched the record without naming it as subject" do
      bulk_adjust!

      expect(timeline_for(product).events).to be_empty

      correlated = timeline_for(product).correlated
      expect(correlated.events.map(&:action)).to include("price.bulk_adjusted")
    end

    # The bug this guards is silent and specific. `where.not(subject_type: t,
    # subject_id: i)` compiles to NOT (subject_type = t AND subject_id = i),
    # which is NULL -- and therefore excludes the row -- when subject_type IS
    # NULL. An unsubjected action is exactly that row, so the natural spelling
    # drops the entire population this section exists for.
    it "does not drop events whose subject is NULL" do
      bulk_adjust!

      event = AuditLog::Event.for_action("price.bulk_adjusted").first
      expect(event.subject_type).to be_nil
      expect(timeline_for(product).correlated.events).to include(event)
    end

    it "excludes the subject-matched events already listed above it" do
      order = as_actor(staff) do
        o = Order.create!(customer: create_customer, created_by: staff,
                          line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
        AuditLog.notify("order.created", order_id: o.id, reference: o.reference,
                                         customer_name: o.customer.name, line_count: 1)
        o
      end

      subject_matched = timeline_for(order).events.to_a
      expect(subject_matched).not_to be_empty
      expect(timeline_for(order).correlated.events.to_a).not_to include(*subject_matched)
    end

    it "ignores out-of-band changes, which correlate to nothing by definition" do
      # request_id IS NULL: a console session, a migration, a psql connection.
      Product.where(id: product.id).update_all(price_cents: 2_500)

      correlated = timeline_for(product).correlated
      expect(correlated.scanned).to eq(0)
      expect(correlated.events).to be_empty
    end

    it "reports what it scanned and says so when it ran out of budget" do
      as_actor(staff) { 5.times { |i| product.update!(price_cents: 2_000 + i) } }

      capped = timeline_for(product).correlated(limit: 3)
      expect(capped.scanned).to eq(3)
      expect(capped).to be_truncated

      full = timeline_for(product).correlated(limit: 50)
      expect(full.scanned).to eq(5)
      expect(full).not_to be_truncated
    end

    it "date-bounds the event lookup so the query can prune partitions" do
      bulk_adjust!

      sql = timeline_for(product).correlated.events.to_sql
      expect(sql).to match(/occurred_at/i)
      expect(sql).to include("IS DISTINCT FROM")
    end
  end
end

# The bounded drill-down both screens share. This used to be spelled twice --
# once here and once on the actor screen -- and only one of the two carried a
# date bound.
RSpec.describe AuditLog::Change, ".grouped_by_request" do
  let(:staff) { create_user(role: "staff") }

  it "returns {} for an empty page without issuing a query" do
    expect(described_class.grouped_by_request([])).to eq({})
  end

  it "groups a page's change rows by request_id" do
    order = as_actor(staff) do
      o = Order.create!(customer: create_customer, created_by: staff,
                        line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      AuditLog.notify("order.created", order_id: o.id, reference: o.reference,
                                       customer_name: o.customer.name, line_count: 1)
      o
    end

    event   = AuditLog::Event.for_subject("Order", order.id).first
    grouped = described_class.grouped_by_request([event])

    expect(grouped.keys).to eq([event.request_id])
    # One form submit, several records: ONE expandable row, not N unrelated ones.
    expect(grouped[event.request_id].map(&:record_type)).to include("Order", "LineItem")
  end

  # `WHERE request_id IN (...)` names occurred_at not at all, so the planner
  # eliminates no partition and the query touches all of them -- six today, 84 at
  # a 7-year horizon, on every page render. The events carry their own
  # occurred_at, so the bound is free. Same reasoning as RequestDrillDown.
  it "bounds the query on occurred_at, derived from the page's own events" do
    event     = AuditLog::Event.new(request_id: SecureRandom.uuid_v7, occurred_at: Time.current)
    statements = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].include?("audit_changes")
    end

    described_class.grouped_by_request([event])
    ActiveSupport::Notifications.unsubscribe(sub)

    expect(statements).not_to be_empty
    expect(statements.last).to match(/occurred_at/i)
  end

  # An event with no occurred_at cannot supply a window, and guessing one would
  # be the quiet under-report this whole bound exists to avoid. Correct and slow
  # beats fast and wrong -- RequestDrillDown makes the same call for a v4 id.
  it "falls back to an unbounded query rather than inventing a window" do
    event = AuditLog::Event.new(request_id: SecureRandom.uuid_v7, occurred_at: nil)

    expect { described_class.grouped_by_request([event]) }.not_to raise_error
  end
end
