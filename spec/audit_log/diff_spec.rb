# frozen_string_literal: true

require "rails_helper"

RSpec.describe "what the trigger records" do
  let(:user) { create_user }

  it "records only the columns that actually changed" do
    product = create_product(price_cents: 100)
    as_actor(user) { product.update!(price_cents: 250) }

    change = changes_for(product).last
    expect(change.diff.keys).to eq(["price_cents"])
    expect(change.changed_columns).to eq(["price_cents"])
  end

  it "writes nothing for a save that changed nothing" do
    product = create_product
    before = changes_for(product).count

    as_actor(user) { product.save! }

    expect(changes_for(product).count).to eq(before)
  end

  it "writes nothing when only excluded columns changed" do
    product = create_product
    before = changes_for(product).count

    as_actor(user) { product.touch }

    expect(changes_for(product).count).to eq(before)
  end

  it "never copies credential columns into the audit log" do
    subject_user = create_user
    # Written directly rather than through an auth gem's `password=`: what is
    # under test is that the trigger's exclusion list keeps the column out of the
    # diff, and that is a property of the column name, not of how it got set.
    as_actor(user) { subject_user.update!(encrypted_password: "a-brand-new-hash") }

    all_columns = changes_for(subject_user).flat_map(&:changed_columns)
    expect(all_columns).not_to include("encrypted_password")

    # And the insert row must not carry it either.
    insert = changes_for(subject_user).first
    expect(insert.diff.keys).not_to include("encrypted_password", "reset_password_token")
  end

  it "still audits non-credential changes to the actor table" do
    subject_user = create_user(role: "staff")
    as_actor(user) { subject_user.update!(role: "manager") }

    expect(changes_for(subject_user).last.diff).to eq("role" => %w[staff manager])
  end

  it "records the full final state on delete, so the record survives its row" do
    product = create_product(price_cents: 777)
    as_actor(user) { product.destroy! }

    change = changes_for(product).last
    expect(change.operation).to eq("D")
    expect(change.diff["price_cents"]).to eq([777, nil])
    expect(change.diff["sku"].first).to be_present
  end

  it "distinguishes 'set on insert' from 'cleared'" do
    customer = nil
    as_actor(user) { customer = Customer.create!(name: "X", notes: "original") }
    as_actor(user) { customer.update!(notes: nil) }

    insert, update = changes_for(customer).to_a
    expect(insert.diff["notes"]).to eq([nil, "original"])   # [old, new] -> set
    expect(update.diff["notes"]).to eq(["original", nil])   # [old, new] -> cleared
  end

  it "populates changed_columns so the GIN index can answer 'who touched status'" do
    order = nil
    as_actor(user) { order = Order.create!(customer: create_customer, created_by: user) }
    as_actor(user) { order.update!(status: "submitted", notes: "why") }

    matched = AuditLog::Change.for_record("Order", order.id).touching_columns("status")

    # Two: the UPDATE, and the INSERT -- an insert diff lists every column, so it
    # genuinely did "touch status". That is the right answer for an auditor
    # asking who ever set this field, and callers wanting only edits add
    # `.where(operation: "U")`.
    expect(matched.count).to eq(2)
    expect(matched.map(&:operation)).to match_array(%w[I U])
    expect(matched.find { |c| c.operation == "U" }.changed_columns).to match_array(%w[status notes])

    expect(AuditLog::Change.for_record("Order", order.id).touching_columns("nonexistent")).to be_empty
  end
end
