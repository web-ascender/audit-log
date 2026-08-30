# frozen_string_literal: true

require "rails_helper"

# R4: one user action reads as one action, however many rows it touched.
RSpec.describe "request correlation" do
  let(:user) { create_user }
  let(:customer) { create_customer }

  it "groups a parent and its nested children under one request_id" do
    products = Array.new(3) { create_product }
    request_id = nil

    as_actor(user) do
      request_id = AuditLog::Current.request_id
      Order.create!(
        customer: customer, created_by: user,
        line_items_attributes: products.map { |p| { product_id: p.id, quantity: 2 } }
      )
    end

    changes = AuditLog::Change.where(request_id: request_id)

    # One order + three line items, all under one id.
    expect(changes.where(record_type: "Order").count).to eq(1)
    expect(changes.where(record_type: "LineItem").count).to eq(3)
    expect(changes.pluck(:request_id).uniq).to eq([request_id])
  end

  it "writes exactly one narrative row for that whole action" do
    request_id = nil

    as_actor(user) do
      request_id = AuditLog::Current.request_id
      order = Order.create!(customer: customer, created_by: user,
                            line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      AuditLog.notify("order.created", order_id: order.id, reference: order.reference,
                                       customer_name: customer.name, line_count: 1)
    end

    events = AuditLog::Event.where(request_id: request_id)
    expect(events.count).to eq(1)
    expect(events.first.summary).to include("Drafted order")
    expect(events.first.actor_label).to eq(user.to_label)
  end

  it "gives separate actions separate request_ids" do
    ids = 2.times.map do
      as_actor(user) do
        Order.create!(customer: customer, created_by: user)
        AuditLog::Current.request_id
      end
    end

    expect(ids.uniq.size).to eq(2)
  end

  it "uses a UUIDv7 so the request_id index stays insert-ordered" do
    id = AuditLog::Context.new_request_id
    # Version nibble is the first character of the third group.
    expect(id.split("-")[2][0]).to eq("7")
  end

  it "leaves request_id NULL for a write with no correlation context" do
    AuditLog::Current.reset
    product = create_product

    expect(changes_for(product).last.request_id).to be_nil
    expect(changes_for(product).last.actor_label).to be_nil
  end

  # config.correlated_connections decides who pays for the correlation round trip.
  # It does NOT decide what is audited -- the triggers do, per table -- and the
  # name was chosen to stop that misreading. These two examples are what make the
  # distinction true rather than merely asserted in a comment.
  # These are CONNECTION names, not database names, and the difference used to be
  # discoverable only by noticing that every audit row had a NULL actor. The
  # option was called `correlated_databases` until 2026-08-30 and a real app was
  # configured with its database name, which matched nothing and switched
  # correlation off in silence.
  describe "the connection-name contract" do
    # THE ASSUMPTION THE DEFAULT RESTS ON, and it is Rails', not ours: a flat
    # single-database database.yml -- no `primary:` key anywhere in it, which is
    # what spec/dummy has and what most apps have -- is still NAMED "primary".
    # If Rails ever stopped normalizing that, `%w[primary]` would match nothing
    # and every adopter on a flat config would silently stop correlating. This
    # example is the only thing that would say so.
    it "names a flat, single-database config \"primary\"" do
      expect(ActiveRecord::Base.connection.pool.db_config.name).to eq("primary")
      expect(AuditLog.config.correlated_connections).to include("primary")
      expect(AuditLog::Context.send(:stamped_database?, ActiveRecord::Base.connection)).to be true
    end

    # The boot check that turns the silent failure into a loud one, exercised
    # through the method the engine actually calls.
    describe "the boot check" do
      def verify(configured, known: %w[primary queue])
        allow(AuditLog.config).to receive(:correlated_connections).and_return(configured)
        AuditLog.config.verify_correlated_connections!(known)
      end

      # The mistake this was built for: a database name where a connection name
      # belongs. It is what an app was really configured with.
      it "raises when nothing matches, naming both sides" do
        expect { verify(%w[ngen_ipc_production]) }
          .to raise_error(AuditLog::Error, /names no connection.*ngen_ipc_production.*primary/m)
      end

      it "raises rather than correlating nothing on an empty list" do
        expect { verify([]) }.to raise_error(AuditLog::Error)
      end

      # `%w[primary replica]` is a correct configuration in an app whose test
      # environment has no replica. Raising there would refuse to boot something
      # that works, so a partial miss warns and returns what it could not find.
      it "only warns when some names match and some do not" do
        expect(Rails.logger).to receive(:warn).with(/replica.*no actor or request_id/m)

        expect(verify(%w[primary replica])).to eq(%w[replica])
      end

      it "is silent when every name matches" do
        expect(Rails.logger).not_to receive(:warn)

        expect(verify(%w[primary queue])).to eq([])
      end
    end
  end

  describe "config.correlated_connections" do
    # Clears the GUCs on the server as well as the per-connection memo, so the
    # connection genuinely carries no stamp. forget_stamp! alone only drops the
    # memo; the session-level SET from an earlier statement would survive it.
    def uncorrelate_the_connection!
      conn = ApplicationRecord.connection
      AuditLog::Current.reset
      AuditLog::Context.forget_stamp!(conn)
      AuditLog::Context.ensure_stamped!(conn)

      allow(AuditLog.config).to receive(:correlated_connections).and_return([])
      AuditLog::Context.forget_stamp!(conn)
      conn
    end

    it "stops stamping a database it does not name" do
      conn = uncorrelate_the_connection!

      as_actor(user) { AuditLog::Context.ensure_stamped!(conn) }

      expect(conn.instance_variable_get(:@audit_stamp)).to be_nil
    end

    # The property the name rests on. Leaving a database out is not a way to
    # switch auditing off: every row is still recorded, it just arrives
    # uncorrelated -- indistinguishable from a console session.
    it "still audits every write on that database, with a NULL actor" do
      uncorrelate_the_connection!

      product = as_actor(user) { create_product }
      change  = changes_for(product).last

      expect(change).to be_present
      expect(change.request_id).to be_nil
      expect(change.actor_id).to be_nil
      expect(change.actor_label).to be_nil
      expect(change.diff.keys).to include("sku", "name")
    end
  end

  it "snapshots the actor label rather than joining to it" do
    order = nil
    as_actor(user) { order = Order.create!(customer: customer, created_by: user) }

    original = user.to_label
    user.update!(name: "Renamed Person")

    # The audit row still says what the user was called when they acted.
    expect(changes_for(order).first.actor_label).to eq(original)
    expect(changes_for(order).first.actor_label).not_to eq(user.reload.to_label)
  end

  it "does not leak one actor's identity into the next unit of work" do
    other = create_user(name: "Other Person")

    as_actor(user) { create_product }
    as_actor(other) { create_product }
    AuditLog::Current.reset
    last = create_product

    expect(changes_for(last).last.actor_label).to be_nil
  end
end

