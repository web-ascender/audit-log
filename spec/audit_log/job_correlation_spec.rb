# frozen_string_literal: true

require "rails_helper"

# The plan calls this the highest-value test after the coverage guard, because
# the mechanism depends on framework-internal ordering that reading source does
# not settle.
RSpec.describe "background job correlation", :job do
  let(:user) { create_user(name: "Jane Doe", email: "jane@example.com") }
  let(:order) do
    as_actor(user) do
      o = Order.create!(customer: create_customer, created_by: user, status: "approved")
      o.line_items.create!(product: create_product, quantity: 1)
      o
    end
  end

  it "attributes the job's writes to the user who enqueued it" do
    originating_request_id = nil

    perform_enqueued_jobs do
      as_actor(user) do
        originating_request_id = AuditLog::Current.request_id
        OrderFulfillmentJob.perform_later(order)
      end
    end

    shipment = order.reload.shipments.last
    change   = AuditLog::Change.for_record("Shipment", shipment.id).first

    # Inherited: the job acted on Jane's behalf, so her activity screen shows it.
    expect(change.actor_id).to eq(user.id)
    expect(change.actor_label).to eq("Jane Doe <jane@example.com>")

    # Fresh: a new execution is a new action, not a continuation of the request.
    expect(change.request_id).to be_present
    expect(change.request_id).not_to eq(originating_request_id)

    # ...but linked to its cause, so "what user action caused this job" is one lookup.
    event = AuditLog::Event.find_by(request_id: change.request_id, action: "order.shipped")
    # A real column since the promote migration, not a metadata key -- metadata
    # holds the action's own payload and must not carry framework plumbing.
    expect(event.caused_by_request_id).to eq(originating_request_id)
    expect(event.metadata).not_to have_key("caused_by_request_id")
  end

  it "captures the origin in serialize, so bulk enqueue keeps the actor" do
    # ActiveJob.perform_all_later and Solid Queue's enqueue_all skip the enqueue
    # callbacks. If the origin were captured in around_enqueue, every bulk
    # enqueue would silently lose its actor.
    payloads = as_actor(user) do
      [OrderFulfillmentJob.new(order), OrderFulfillmentJob.new(order)].map(&:serialize)
    end

    payloads.each do |payload|
      expect(payload["audit_origin"]["actor_id"]).to eq(user.id)
      expect(payload["audit_origin"]["actor_label"]).to eq(user.to_label)
    end
  end

  it "survives a bulk enqueue end to end" do
    perform_enqueued_jobs do
      as_actor(user) { ActiveJob.perform_all_later([OrderFulfillmentJob.new(order)]) }
    end

    shipment = order.reload.shipments.last
    expect(AuditLog::Change.for_record("Shipment", shipment.id).first.actor_id).to eq(user.id)
  end

  it "keeps the ORIGINAL origin across a retry rather than recapturing" do
    job = as_actor(user) { OrderFulfillmentJob.new(order).tap(&:serialize) }
    original = job.audit_origin.dup

    other = create_user(name: "Someone Else")
    as_actor(other) { job.serialize }

    expect(job.audit_origin).to eq(original)
  end

  it "marks a job with no enqueuing context as source: system" do
    perform_enqueued_jobs do
      AuditLog::Current.reset
      NightlyPriceReviewJob.perform_later(percent: 5)
    end

    event = AuditLog::Event.where(action: "price.bulk_adjusted").last
    expect(event.source).to eq("system")
    expect(event.actor_id).to be_nil
    expect(event.actor_label).to be_nil
  end

  it "deserializes the origin back onto the job" do
    payload = as_actor(user) { OrderFulfillmentJob.new(order).serialize }
    revived = ActiveJob::Base.deserialize(payload)
    revived.send(:deserialize_arguments_if_needed)

    expect(revived.audit_origin["actor_label"]).to eq(user.to_label)
  end

  it "carries no GlobalID in the audit payload, so a deleted actor cannot break it" do
    payload = as_actor(user) { OrderFulfillmentJob.new(order).serialize }
    expect(payload["audit_origin"].values.grep(String).grep(/gid:/)).to be_empty
  end

  it "emits job.performed so job activity is never narrative-less" do
    perform_enqueued_jobs do
      as_actor(user) { OrderFulfillmentJob.perform_later(order) }
    end

    expect(AuditLog::Event.where(action: "job.performed").last.metadata["job_class"])
      .to eq("OrderFulfillmentJob")
  end
end
