# frozen_string_literal: true

require "rails_helper"

# AuditLog.audited is sugar for the explicit
# `transaction do ... AuditLog.notify ... end` form, so what this pins is that it
# is EXACTLY that and nothing else -- same atomicity in both directions (R3) --
# plus the one rule the sugar adds: identity and inputs are eager, outcomes are
# collected after the writes that produce them.
RSpec.describe "AuditLog.audited" do
  let(:user) { create_user }

  # 1 line item x 2 @ 1_000 before the block runs, x 2 @ 2_500 after it.
  def build_order(quantity: 2)
    order = Order.create!(customer: create_customer, created_by: user)
    order.line_items.create!(product: create_product(price_cents: 1_000), quantity: quantity)
    order.reload
  end

  def submit(order)
    AuditLog.audited("order.submitted", on: order,
                     order_id: order.id, reference: order.reference,
                     customer_name: order.customer.name) do |audit|
      order.update!(status: "submitted", submitted_at: Time.current)
      order.line_items.each { |item| item.update!(unit_price_cents: 2_500) }

      audit[:line_count]  = order.line_items.size
      audit[:total_cents] = order.line_items.reload.sum(&:total_cents)
      order
    end
  end

  it "merges the eager keywords and the collected outcomes into one payload" do
    order = build_order

    as_actor(user) { submit(order) }

    event = AuditLog::Event.where(action: "order.submitted").last
    expect(event.metadata).to include(
      "order_id" => order.id, "reference" => order.reference,
      "customer_name" => order.customer.name, "line_count" => 1
    )
  end

  # THE reason outcomes are collected rather than passed as keywords. Ruby
  # evaluates kwargs before the block, so `total_cents: total_cents` up top would
  # record 2_000 -- the pre-submit total, under a sentence saying the order was
  # submitted, rendering without complaint.
  it "collects outcomes after the writes, not before them" do
    order = build_order

    as_actor(user) { submit(order) }

    event = AuditLog::Event.where(action: "order.submitted").last
    expect(event.metadata["total_cents"]).to eq(5_000)
    expect(event.metadata["total_cents"]).not_to eq(2_000)
    expect(event.summary).to include("$50.00")
  end

  it "returns the block's value, not the payload" do
    order = build_order

    expect(as_actor(user) { submit(order) }).to eq(order)
  end

  it "files the event and the change rows under one request_id" do
    order = build_order

    as_actor(user) { submit(order) }

    event = AuditLog::Event.where(action: "order.submitted").last
    expect(AuditLog::Change.where(request_id: event.request_id).count).to be > 0
  end

  it "emits an identity-only payload when the block collects nothing" do
    order = build_order

    as_actor(user) do
      AuditLog.audited("order.approved", on: order, order_id: order.id,
                       reference: order.reference, approver: user.to_label) do
        order.update!(status: "approved", approved_at: Time.current)
      end
    end

    expect(AuditLog::Event.where(action: "order.approved").last.metadata)
      .to eq("order_id" => order.id, "reference" => order.reference,
             "approver" => user.to_label)
  end

  describe "atomicity" do
    it "discards the event and the changes when the block raises" do
      order = build_order
      before_changes = AuditLog::Change.count
      before_events  = AuditLog::Event.count

      expect {
        as_actor(user) do
          AuditLog.audited("order.submitted", on: order, order_id: order.id) do
            order.update!(status: "submitted")
            raise "boom"
          end
        end
      }.to raise_error("boom")

      expect(order.reload.status).to eq("draft")
      expect(AuditLog::Change.count).to eq(before_changes)
      expect(AuditLog::Event.count).to eq(before_events)
    end

    it "discards both on ActiveRecord::Rollback, and returns nil" do
      order = build_order
      before_events = AuditLog::Event.count

      result = as_actor(user) do
        AuditLog.audited("order.submitted", on: order, order_id: order.id) do
          order.update!(status: "submitted")
          raise ActiveRecord::Rollback
        end
      end

      expect(result).to be_nil
      expect(order.reload.status).to eq("draft")
      expect(AuditLog::Event.count).to eq(before_events)
    end

    # The emit is the last statement INSIDE the transaction, not an after_commit
    # hook. Emitting on commit instead would leave the changes standing with no
    # narrative when the event write failed -- see spec/audit_log/atomicity_spec.rb.
    it "rolls the business change back if the event write fails" do
      order = build_order
      allow(AuditLog::Event).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { as_actor(user) { submit(order) } }.to raise_error(ActiveRecord::StatementInvalid)

      expect(order.reload.status).to eq("draft")
    end
  end

  describe "the eager/collected split" do
    it "raises when a key is set in both slots, and names the fix" do
      order = build_order

      expect {
        as_actor(user) do
          AuditLog.audited("order.submitted", on: order, total_cents: order.total_cents) do |audit|
            order.line_items.each { |item| item.update!(unit_price_cents: 2_500) }
            audit[:total_cents] = 5_000
          end
        end
      }.to raise_error(AuditLog::Error, /:total_cents.*Remove it from the keywords/m)
    end

    it "catches the overwrite through merge! as well as through []=" do
      order = build_order

      expect {
        as_actor(user) do
          AuditLog.audited("order.submitted", on: order, order_id: order.id) do |audit|
            audit.merge!(order_id: 999)
          end
        end
      }.to raise_error(AuditLog::Error, /:order_id/)
    end

    # A string key against a symbol keyword would arrive as two keys, collapse in
    # EventSubscriber#emit's symbolize_keys, and silently take whichever landed
    # last -- an overwrite that walks past the guard. Payload normalises instead.
    it "catches the overwrite when the block spells the key as a string" do
      order = build_order

      expect {
        as_actor(user) do
          AuditLog.audited("order.submitted", on: order, order_id: order.id) do |audit|
            audit["order_id"] = 999
          end
        end
      }.to raise_error(AuditLog::Error, /:order_id/)
    end

    it "rolls the writes back when the guard fires" do
      order = build_order

      expect {
        as_actor(user) do
          AuditLog.audited("order.submitted", on: order, order_id: order.id) do |audit|
            order.update!(status: "submitted")
            audit[:order_id] = 1
          end
        end
      }.to raise_error(AuditLog::Error)

      expect(order.reload.status).to eq("draft")
    end
  end

  describe "AuditLog::Payload" do
    subject(:payload) { AuditLog::Payload.new("order.submitted", order_id: 7) }

    it "accepts a hash, keywords, and assignment" do
      payload.merge!({line_count: 2})
      payload.merge!(total_cents: 500)
      payload[:reference] = "SO-1"

      expect(payload.to_h).to eq(order_id: 7, line_count: 2, total_cents: 500, reference: "SO-1")
    end

    it "normalises string keys to symbols" do
      payload["line_count"] = 2
      payload.merge!("total_cents" => 500)

      expect(payload.to_h).to eq(order_id: 7, line_count: 2, total_cents: 500)
    end

    # `merge` would build a hash and discard it: the keys are computed, the event
    # emits without them, the summary renders a gap and nothing raises.
    it "refuses the non-mutating merge rather than silently dropping the keys" do
      expect { payload.merge(line_count: 2) }
        .to raise_error(AuditLog::Error, /Use merge!/)
    end

    it "reads back and answers key?" do
      expect(payload[:order_id]).to eq(7)
      expect(payload).to be_key(:order_id)
      expect(payload).not_to be_key(:line_count)
    end

    # Wrapped, not subclassed -- so `delete`, `clear` and `replace` are not part
    # of what a block may do to an audit payload. See the comment in payload.rb.
    it "does not publish the rest of Hash" do
      expect(payload).not_to respond_to(:delete)
      expect(payload).not_to respond_to(:clear)
      expect(payload).not_to be_a(Hash)
    end

    it "hands out a copy, so a stray reference cannot mutate what was emitted" do
      payload.to_h[:injected] = true
      expect(payload.to_h).not_to have_key(:injected)
    end
  end

  # Same contract as AuditLog.notify: an unregistered action is a no-op, so the
  # work still happens and simply produces no narrative row.
  it "still runs the block for an unregistered action, and writes no event" do
    order = build_order

    expect {
      as_actor(user) do
        AuditLog.audited("order.not_registered", on: order) { order.update!(status: "submitted") }
      end
    }.not_to change(AuditLog::Event, :count)

    expect(order.reload.status).to eq("submitted")
  end

  it "requires a block, and points at notify" do
    expect { AuditLog.audited("order.submitted", order_id: 1) }
      .to raise_error(ArgumentError, /requires a block.*AuditLog\.notify/m)
  end

  describe "on:" do
    it "opens the transaction on the object it is given" do
      order = build_order
      expect(Order).to receive(:transaction).at_least(:once).and_call_original
      as_actor(user) do
        AuditLog.audited("order.deleted", on: order, order_id: order.id) { }
      end
    end

    it "defaults to ActiveRecord::Base" do
      expect(ActiveRecord::Base).to receive(:transaction).and_call_original
      as_actor(user) { AuditLog.audited("customer.created", customer_id: 1, name: "Acme") { } }
    end
  end
end
