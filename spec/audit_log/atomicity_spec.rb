# frozen_string_literal: true

require "rails_helper"

# R3: the audit record commits and rolls back with the change it describes.
RSpec.describe "atomicity" do
  let(:user) { create_user }

  it "leaves no audit rows behind when the transaction rolls back" do
    user               # force the actor's own creation before measuring
    customer = create_customer
    before_changes = AuditLog::Change.count
    before_events  = AuditLog::Event.count

    as_actor(user) do
      expect {
        ActiveRecord::Base.transaction do
          order = Order.create!(customer: customer, created_by: user)
          AuditLog.notify("order.created", order_id: order.id, reference: order.reference,
                                           customer_name: "X", line_count: 0)
          raise ActiveRecord::Rollback
        end
      }.not_to raise_error
    end

    expect(AuditLog::Change.count).to eq(before_changes)
    expect(AuditLog::Event.count).to eq(before_events)
  end

  it "rolls the business change back if the audit event write fails" do
    # A swallowed audit failure would mean the change rows commit while the
    # narrative row silently vanishes. ActiveSupport::EventReporter rescues
    # subscriber exceptions by default; the engine sets raise_on_error so this
    # surfaces instead. See lib/audit_log/engine.rb.
    allow(AuditLog::Event).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")

    order_count = Order.count

    expect {
      as_actor(user) do
        ActiveRecord::Base.transaction do
          order = Order.create!(customer: create_customer, created_by: user)
          AuditLog.notify("order.created", order_id: order.id, reference: order.reference,
                                           customer_name: "X", line_count: 0)
        end
      end
    }.to raise_error(ActiveRecord::StatementInvalid)

    expect(Order.count).to eq(order_count)
  end
end
