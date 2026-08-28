# frozen_string_literal: true

require "rails_helper"

# The three questions the design exists to answer, asserted as queries rather
# than as prose.
RSpec.describe "the three auditor questions" do
  let(:jane) { create_user(name: "Jane Doe", email: "jane@example.com") }
  let(:raj)  { create_user(name: "Raj Patel", email: "raj@example.com", role: "staff") }
  let(:customer) { create_customer }
  let(:range) { 7.days.ago..Time.current }

  before do
    # Created outside the audited block on purpose: anything written inside
    # as_actor becomes part of that action, which would (correctly) make the
    # drill-down below list a Customer and a Product too.
    customer
    product = create_product

    as_actor(jane) do
      @order = Order.create!(customer: customer, created_by: jane,
                             line_items_attributes: [{ product_id: product.id, quantity: 2 }])
      AuditLog.notify("order.created", order_id: @order.id, reference: @order.reference,
                                       customer_name: customer.name, line_count: 1)
    end
    as_actor(jane) { @order.submit! }
    as_actor(raj)  { create_product }
  end

  describe "Q1 -- what did Jane modify or delete last week?" do
    let(:query) { AuditLog::ActorActivity.new(actor: jane, range: range) }

    it "lists her actions, newest first, with a readable summary" do
      expect(query.events.map(&:action)).to eq(%w[order.submitted order.created])
      expect(query.events.first.summary).to include("Submitted order")
      expect(query.events.first.actor_label).to eq("Jane Doe <jane@example.com>")
    end

    it "answers 'modify or delete' from the record layer, not the registry" do
      modifications = query.changes(operations: %w[U D])
      expect(modifications).to be_present
      expect(modifications.map(&:record_type)).to all(be_in(%w[Order LineItem]))
    end

    it "excludes other people's activity" do
      expect(query.changes.map(&:actor_id).uniq).to eq([jane.id])
    end

    it "supports a single calendar day in the auditor's zone" do
      today = AuditLog::ActorActivity.new(actor: jane, range: Time.zone.today.all_day)
      expect(today.events).to be_present
    end

    it "drills into a page of actions with ONE query, not N+1" do
      events = query.events.to_a
      grouped = query.changes_for(events)

      expect(grouped.keys).to match_array(events.map(&:request_id))
      # The create action touched an Order and a LineItem -- one row in the
      # timeline, two records underneath it.
      creation = events.find { |e| e.action == "order.created" }
      expect(grouped[creation.request_id].map(&:record_type)).to match_array(%w[Order LineItem])
    end
  end

  describe "Q2 -- all modifications to a model: who, when, which fields" do
    it "returns one record's whole history" do
      history = AuditLog::RecordHistory.new(record_type: "Order", record_id: @order.id).changes
      expect(history.map(&:operation)).to include("I", "U")
      expect(history.map(&:actor_label).uniq).to eq(["Jane Doe <jane@example.com>"])
    end

    it "returns every record of a class in a window" do
      all_orders = AuditLog::RecordHistory.new(record_type: "Order", range: range).changes
      expect(all_orders).to be_present
    end

    it "narrows to specific fields via the GIN index" do
      narrowed = AuditLog::RecordHistory.new(
        record_type: "Order", range: range, columns: ["status"]
      ).changes

      expect(narrowed).to be_present
      expect(narrowed.map(&:changed_columns)).to all(include("status"))
    end

    it "names the actor with no join and no lookup table" do
      change = AuditLog::RecordHistory.new(record_type: "Order", record_id: @order.id).changes.first
      expect(change.actor_display).to eq("Jane Doe <jane@example.com>")
    end

    it "keeps working after the acting user is deleted" do
      # Pin the specific row, because destroying the user nullifies orders.created_by_id
      # and therefore writes a NEW change row of its own.
      row_id = AuditLog::RecordHistory.new(record_type: "Order", record_id: @order.id)
                                     .changes.first.id
      jane.destroy!

      change = AuditLog::Change.find(row_id)
      expect(change.actor_label).to eq("Jane Doe <jane@example.com>")
      expect(change.actor_display).to eq("Jane Doe <jane@example.com>")
    end
  end

  describe "Q3 -- all order.submitted events and who triggered them" do
    let(:report) { AuditLog::ActionReport.new(action: "order.submitted", range: range) }

    it "lists them with no join at all" do
      expect(report.events.count).to eq(1)
      expect(report.events.first.actor_label).to eq("Jane Doe <jane@example.com>")
    end

    it "rolls up by actor for the screen header" do
      expect(report.by_actor).to eq({ ["User", jane.id, "Jane Doe <jane@example.com>"] => 1 })
    end

    it "surfaces domain values from metadata without touching the orders table" do
      expect(report.events.first.metadata["total_cents"]).to be_present
      @order.destroy!
      expect(report.events.first.metadata["reference"]).to be_present
    end

    it "gets its action picker from the registry, in memory" do
      expect(AuditLog::ActionReport.available_actions).to include("order.submitted")
    end
  end

  describe "the completeness reconciler" do
    it "flags a change with no registered action covering it" do
      as_actor(raj) { create_product }   # no notify -> uncovered

      rows = AuditLog::Reconciler.new(range: 1.hour.ago..Time.current).uncovered_requests
      expect(rows.map(&:record_types).flatten).to include("Product")
    end

    it "does not flag a request that has a registered action" do
      rows = AuditLog::Reconciler.new(range: 1.hour.ago..Time.current).uncovered_requests
      submitted = AuditLog::Event.find_by(action: "order.submitted")
      expect(rows.map(&:request_id)).not_to include(submitted.request_id)
    end
  end

  describe "out-of-band writes" do
    it "surfaces uncorrelated changes as their own category" do
      AuditLog::Current.reset
      create_product

      expect(AuditLog::Change.out_of_band.occurred_between(range)).to be_present
      expect(AuditLog::Change.out_of_band.first.actor_display).to eq("System")
    end
  end
end
