# frozen_string_literal: true

require "rails_helper"

# The cases paper_trail and audited miss, and the entire justification for
# putting change capture in the database instead of in Active Record callbacks.
# Every example here writes through a path where NO Active Record callback runs.
RSpec.describe "write paths that bypass Active Record callbacks" do
  let(:user) { create_user }

  it "captures update_all, with the acting user attached" do
    product = create_product(price_cents: 1_000)

    as_actor(user) { Product.where(id: product.id).update_all(price_cents: 1_500) }

    change = changes_for(product).last
    expect(change.operation).to eq("U")
    expect(change.diff).to eq("price_cents" => [1_000, 1_500])
    expect(change.actor_label).to eq(user.to_label)

    # The part that is easy to get wrong: update_all opens no transaction, so a
    # correlation mechanism hooked to transaction start would capture the change
    # but lose the actor. See AuditLog::TransactionStamp.
    expect(change.request_id).to be_present
  end

  it "captures delete_all" do
    product = create_product
    as_actor(user) { Product.where(id: product.id).delete_all }

    change = changes_for(product).last
    expect(change.operation).to eq("D")
    expect(change.diff["sku"].last).to be_nil
    expect(change.actor_label).to eq(user.to_label)
  end

  it "captures insert_all" do
    sku = "BULK-#{SecureRandom.hex(3).upcase}"
    as_actor(user) do
      Product.insert_all([{ sku: sku, name: "Bulk", price_cents: 500,
                            created_at: Time.current, updated_at: Time.current }])
    end

    product = Product.find_by!(sku: sku)
    expect(changes_for(product).where(operation: "I")).to be_present
  end

  it "captures upsert_all on both the insert and the update" do
    sku = "UPS-#{SecureRandom.hex(3).upcase}"
    row = { sku: sku, name: "Upserted", price_cents: 100,
            created_at: Time.current, updated_at: Time.current }

    as_actor(user) { Product.upsert_all([row], unique_by: :sku) }
    product = Product.find_by!(sku: sku)

    as_actor(user) { Product.upsert_all([row.merge(price_cents: 200)], unique_by: :sku) }

    expect(changes_for(product).pluck(:operation)).to eq(%w[I U])
    expect(changes_for(product).last.diff["price_cents"]).to eq([100, 200])
  end

  it "captures raw SQL that never touches Active Record at all" do
    customer = create_customer
    as_actor(user) do
      ActiveRecord::Base.connection.execute(
        "UPDATE customers SET status = 'reviewed' WHERE id = #{customer.id}"
      )
    end

    expect(changes_for(customer).last.diff).to eq("status" => %w[active reviewed])
  end

  it "captures a dependent: :delete_all cascade, which runs no callbacks" do
    order = nil
    shipment = nil

    as_actor(user) do
      order = Order.create!(customer: create_customer, created_by: user)
      shipment = order.shipments.create!(carrier: "UPS", tracking_number: "1Z1")
    end

    as_actor(user) { order.destroy! }

    expect(changes_for(shipment).last.operation).to eq("D")
  end

  it "captures a dependent: :destroy cascade under the same request_id as its parent" do
    order = nil
    item  = nil

    as_actor(user) do
      order = Order.create!(customer: create_customer, created_by: user)
      item  = order.line_items.create!(product: create_product, quantity: 2)
    end

    destroy_request_id = nil
    as_actor(user) do
      destroy_request_id = AuditLog::Current.request_id
      order.destroy!
    end

    expect(changes_for(item).last.operation).to eq("D")
    expect(changes_for(item).last.request_id).to eq(destroy_request_id)
    expect(changes_for(order).last.request_id).to eq(destroy_request_id)
  end
end
