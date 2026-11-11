# frozen_string_literal: true

module AuditContextHelpers
  # The spec equivalent of AuditLog::ControllerContext: mint a correlation id,
  # set the actor, run the block.
  def as_actor(actor, source: "web", &block)
    AuditLog::Current.set(
      request_id: AuditLog::Context.new_request_id,
      actor: actor,
      source: source,
      &block
    )
  end

  # A correlation identity as PRIMITIVES (DESIGN §6.2), for the examples where a
  # persisted User would put its own audited INSERT among the very rows being
  # read -- or into the cleanup of a group that runs outside a fixture
  # transaction. Pairs with `acting_as`.
  def audit_identity(label, id)
    { request_id: AuditLog::Context.new_request_id,
      actor_type: "User", actor_id: id, actor_label: label }
  end

  def acting_as(identity, &block)
    AuditLog::Current.set(**identity, &block)
  end

  # No `password:`. The dummy app has no authentication gem and no password
  # column -- see spec/dummy/app/models/user.rb. An actor only has to answer
  # to_label for the audit log's purposes.
  def create_user(name: "Jane Doe", email: nil, role: "manager")
    User.create!(
      name: name,
      email: email || "#{SecureRandom.hex(4)}@example.com",
      role: role
    )
  end

  def create_product(price_cents: 1_000)
    Product.create!(sku: "SKU-#{SecureRandom.hex(3).upcase}", name: "Test product",
                    price_cents: price_cents)
  end

  def create_customer(name: "Test Customer")
    Customer.create!(name: name)
  end

  def changes_for(record)
    AuditLog::Change.for_record(record.class.name, record.id).order(:id)
  end
end
