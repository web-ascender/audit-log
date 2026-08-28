# frozen_string_literal: true

require "rails_helper"

RSpec.describe "the audit bypass" do
  let(:user) { create_user }

  it "refuses callers that are not allowlisted" do
    expect {
      AuditLog.without_logging(reason: "sneaky", by: "SomeRandomClass") { }
    }.to raise_error(AuditLog::BypassNotPermitted)
  end

  it "refuses to run without a reason" do
    expect {
      AuditLog.without_logging(reason: "", by: "CatalogImportJob") { }
    }.to raise_error(ArgumentError)
  end

  it "suppresses change rows inside the block" do
    sku = "BYP-#{SecureRandom.hex(3).upcase}"

    as_actor(user) do
      AuditLog.without_logging(reason: "bulk import", by: "CatalogImportJob") do
        Product.insert_all([{ sku: sku, name: "Bypassed", price_cents: 1,
                              created_at: Time.current, updated_at: Time.current }])
      end
    end

    product = Product.find_by!(sku: sku)
    expect(changes_for(product)).to be_empty
  end

  it "narrates the gap it creates" do
    as_actor(user) do
      AuditLog.without_logging(reason: "bulk import", by: "CatalogImportJob") { }
    end

    event = AuditLog::Event.where(action: "audit.bypass").last
    expect(event.summary).to include("bulk import")
    expect(event.summary).to include("CatalogImportJob")
    expect(AuditLog::Event.where(action: "audit.bypass_completed")).to be_present
  end

  it "restores auditing after the block, even when the block raises" do
    as_actor(user) do
      expect {
        AuditLog.without_logging(reason: "will fail", by: "CatalogImportJob") { raise "boom" }
      }.to raise_error("boom")
    end

    product = as_actor(user) { create_product }
    expect(changes_for(product)).to be_present
  end
end
