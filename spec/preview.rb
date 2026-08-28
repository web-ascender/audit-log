# Dev tool, not part of the suite (no _spec.rb suffix, so it is not auto-collected).
#
#   bundle exec rspec spec/preview.rb
#
# Renders every audit screen to public/_preview_<name>.html so the layout can be
# eyeballed in a browser without signing in.
require "rails_helper"

RSpec.describe "preview", type: :request do
  include AuditContextHelpers

  it "writes every screen to public/" do
    mei  = create_user(name: "Mei Chen",  email: "mei@example.com",  role: "auditor")
    jane = create_user(name: "Jane Doe",  email: "jane@example.com", role: "manager")
    raj  = create_user(name: "Raj Patel", email: "raj@example.com",  role: "staff")

    customers = ["Northwind Supply", "Acme Industrial", "Bluefin Marine"].map { |n| create_customer(name: n) }
    products  = Array.new(5) { |i| create_product(price_cents: (i + 1) * 799) }

    orders = [[jane, customers[0], 3], [raj, customers[1], 2], [jane, customers[2], 4]].map do |user, customer, n|
      as_actor(user) do
        order = Order.create!(customer: customer, created_by: user, notes: "Preview order.",
          line_items_attributes: products.first(n).map { |p| { product_id: p.id, quantity: rand(1..5) } })
        AuditLog.notify("order.created", order_id: order.id, reference: order.reference,
                                        customer_name: customer.name, line_count: n)
        order
      end
    end

    as_actor(jane) { orders[0].submit! }

    # The approval enqueues the shipping job, which is what puts a causal chain on
    # the drill-down screen. Serialize inside the request (JobContext captures the
    # origin there, not in an enqueue callback) and execute the payload, because
    # perform_now would skip serialization and produce a job event with no cause.
    shipping_job = as_actor(jane) do
      orders[0].approve!(by: jane)
      OrderFulfillmentJob.new(orders[0]).tap(&:serialize)
    end
    ActiveJob::Base.execute(shipping_job.serialize)
    AuditLog::Current.reset
    as_actor(raj)  { orders[1].submit! }
    as_actor(jane) { orders[2].cancel!(reason: "customer withdrew") }
    as_actor(raj)  { products[0].update!(price_cents: 1_299) }            # uncovered by the registry
    # A bulk change WITH its narrative -- and price.bulk_adjusted is registered
    # with no `subject:`, because a bulk change has no one aggregate root. It is
    # therefore the action a record timeline built on the subject index alone
    # would lose entirely, and the reason the "Also touched this record" section
    # has something to render on the product preview.
    as_actor(jane) do
      count = Product.active.update_all("price_cents = (price_cents * 103) / 100")
      AuditLog.notify("price.bulk_adjusted", percent: 3, count: count)
    end

    AuditLog::Current.reset
    Customer.where(id: customers[2].id).update_all(status: "dormant")     # out-of-band

    # A redaction, run with NO actor -- exactly how the rake task issues one.
    # This is the NULL-actor case that took the "who triggered it" rollup down,
    # and it is also the only way to preview the redacted-payload state, so both
    # of those screens now have a rendering somebody can actually look at.
    as_actor(jane) do
      AuditLog.notify("customer.updated", customer_id: customers[1].id,
                                          name: customers[1].name, fields: %w[email])
    end
    AuditLog::Current.reset
    AuditLog::Redaction.redact_record!(record_type: "Customer", record_id: customers[1].id,
                                       reason: "DSR-1182")
    AuditLog::Current.reset

    sign_in mei

    # The approval, not a bare creation: it is the one action with a causal chain,
    # so the preview exercises the "caused these" section rather than skipping it.
    event = AuditLog::Event.find_by(action: "order.approved") ||
            AuditLog::Event.where(action: "order.created").first
    pages = {
      "dashboard" => audit.root_path,
      "actors"    => audit.actors_path,
      "activity"  => audit.actor_path(jane.id, actor_type: "User"),
      "changes"   => audit.actor_path(jane.id, actor_type: "User", view: "changes"),
      "records"   => audit.records_path,
      "record"    => audit.record_path("Order"),
      "history"   => audit.record_history_path(record_type: "Order", record_id: orders[0].id),
      "narrative" => audit.record_history_path(record_type: "Order", record_id: orders[0].id,
                                               view: "actions"),
      "timeline"  => audit.record_history_path(record_type: "Order", record_id: orders[0].id,
                                               view: "timeline"),
      # The BOUNDED state, so the disclosure note has a rendering somebody can
      # look at. A disclosure that never renders is a disclosure nobody tested.
      "timelinebd" => audit.record_history_path(record_type: "Order", record_id: orders[0].id,
                                                view: "timeline", days: 30),
      # A PRODUCT, not an order: price.bulk_adjusted carries no subject: lambda,
      # so a product's narrative tab is empty above and populated below. The one
      # screen state that renders the correlated section on its own.
      "correlated" => audit.record_history_path(record_type: "Product", record_id: products[0].id,
                                                view: "actions"),
      "actions"   => audit.actions_path,
      "action"    => audit.action_path("order.submitted"),
      "redaction" => audit.action_path("audit.redaction"),
      "redacted"  => audit.action_path("customer.updated"),
      "outofband" => audit.out_of_band_index_path,
      "request"   => audit.request_path(event.request_id)
      # The ENGINE's screens only. The reference app keeps its own copy of this
      # file that also renders its order/product/customer pages, because those
      # consume the library's query objects and are what a query-object signature
      # change actually breaks. The dummy app has no such screens by design -- it
      # exists to prove the library needs nothing from a host app but config.
    }

    pages.each do |name, path|
      get path
      puts format("%-10s %-52s %s", name, path, response.status)
      next unless response.status == 200
      File.write(Rails.root.join("public", "_preview_#{name}.html"), response.body)
    end
  end
end
