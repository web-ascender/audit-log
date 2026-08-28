# frozen_string_literal: true

require "rails_helper"

RSpec.describe "append-only behaviour" do
  let(:user) { create_user }
  before { as_actor(user) { create_product } }

  it "refuses to update an existing change row" do
    expect { AuditLog::Change.first.update!(record_type: "Tampered") }
      .to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "refuses to destroy an existing change row" do
    expect { AuditLog::Change.first.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "refuses to update an existing event row" do
    as_actor(user) { AuditLog.notify("customer.created", customer_id: 1, name: "X") }
    expect { AuditLog::Event.first.update!(summary: "Tampered") }
      .to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "still allows the subscriber to insert -- readonly? is keyed on persisted?" do
    expect {
      as_actor(user) { AuditLog.notify("customer.created", customer_id: 1, name: "X") }
    }.to change(AuditLog::Event, :count).by(1)
  end
end
