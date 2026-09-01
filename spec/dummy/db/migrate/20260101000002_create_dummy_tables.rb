# frozen_string_literal: true

# A miniature of the reference app's order-entry domain, chosen so the specs
# exercise the parts of the design that are hard: a nested-attributes write that
# touches a parent and many children in one request, a dependent: :destroy
# cascade, a dependent: :delete_all cascade that Active Record callbacks never
# see, and a foreign key (created_by_id) whose name does not match its target.
class CreateDummyTables < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.string :name,  null: false
      t.string :email, null: false
      t.string :role,  null: false, default: "staff"

      # Not an authentication mechanism -- nothing reads these. They exist so
      # spec/audit_log/diff_spec.rb has real credential columns to prove
      # AuditLog::Configuration::DEFAULT_EXCLUDED_COLUMNS keeps out of the diff.
      # Without them that spec passes vacuously, which is worse than not having it.
      t.string :encrypted_password
      t.string :reset_password_token

      t.timestamps
    end
    add_index :users, :email, unique: true

    create_table :customers do |t|
      t.string :name,   null: false
      t.string :email
      t.string :phone
      t.string :status, null: false, default: "active"
      t.text   :notes
      t.timestamps
    end
    add_index :customers, :name

    create_table :products do |t|
      t.string  :sku,         null: false
      t.string  :name,        null: false
      t.text    :description
      t.integer :price_cents, null: false, default: 0
      t.boolean :active,      null: false, default: true
      t.timestamps
    end
    add_index :products, :sku, unique: true

    create_table :orders do |t|
      t.references :customer,    null: false, foreign_key: true
      t.references :created_by,  null: true,  foreign_key: { to_table: :users }
      t.string     :reference,   null: false
      t.string     :status,      null: false, default: "draft"
      t.integer    :total_cents, null: false, default: 0
      t.text       :notes
      t.datetime   :submitted_at
      t.datetime   :approved_at
      t.timestamps
    end
    add_index :orders, :reference, unique: true
    add_index :orders, %i[status created_at]

    create_table :line_items do |t|
      t.references :order,   null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.integer    :quantity,         null: false, default: 1
      t.integer    :unit_price_cents, null: false, default: 0
      t.string     :description
      t.timestamps
    end

    create_table :shipments do |t|
      t.references :order, null: false, foreign_key: true
      t.string     :carrier
      t.string     :tracking_number
      t.string     :status, null: false, default: "pending"
      t.datetime   :shipped_at
      t.timestamps
    end

    # One line per table, beside the table it audits. This is the ENTIRE
    # per-model cost of the design; the models know nothing about it.
    #
    # `users` is audited too. A role change is exactly the kind of privilege
    # escalation an auditor asks about, and leaving the actor table unaudited is
    # the most common way an audit log ends up unable to answer it.
    attach_audit_trigger :users,      model: "User"
    attach_audit_trigger :customers,  model: "Customer"
    attach_audit_trigger :products,   model: "Product"
    attach_audit_trigger :line_items, model: "LineItem"
    attach_audit_trigger :shipments,  model: "Shipment"

    # `orders` is the ONE table here that declares facets, and it is one table on
    # purpose: the claim this library makes is that a table declaring none pays
    # nothing, and an app where every table declares some leaves that untested.
    # Every row written to line_items, shipments, products, customers and users
    # therefore carries dimensions IS NULL, which is what the partial GIN index
    # excludes -- and what schema/query specs assert against.
    #
    # All three names are columns on `orders`, which is the only kind of facet the
    # trigger half can record: it reads the changed ROW, so a conjunction has to
    # fit on one row. `status` is here rather than only the two foreign keys
    # because a facet is not required to be an association -- a scope label is
    # exactly what this half is for, and it is low-cardinality, which is the
    # guidance. `created_by_id` is also the column belongs_to reflection sees as
    # User rather than "CreatedBy", so it keeps the naming-convention trap in view.
    attach_audit_trigger :orders, model: "Order",
      dimensions: %i[customer_id created_by_id status]
  end
end
