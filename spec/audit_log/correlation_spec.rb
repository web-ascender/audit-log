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

  # A rollback must never stamp. The stamp written inside this transaction says
  # B; Current unwinds to A before Active Record rolls back; a stamp in front of
  # the ROLLBACK TO SAVEPOINT would then run inside the ABORTED transaction, fail,
  # and keep the rollback from ever being sent -- replacing the real error with
  # InFailedSqlTransaction and leaving the enclosing transaction aborted. A
  # Current.set block and JobContext's around_perform both unwind exactly like
  # this. Pre-existing on this path; found while reviewing the Sequel one, where
  # it poisoned the pooled connection outright. DESIGN §26.
  it "rolls back, and reports the real error, when the actor changed back inside an aborted transaction" do
    conn  = ActiveRecord::Base.connection
    error = nil

    acting_as(audit_identity("A", 1)) do
      ActiveRecord::Base.transaction(requires_new: true) do
        conn.execute("SELECT 1")
        acting_as(audit_identity("B", 2)) { conn.execute("SELECT 1/0") }
      end
    rescue ActiveRecord::StatementInvalid => e
      error = e
    end

    expect(error.cause).to be_a(PG::DivisionByZero)
    expect(conn.select_value("SELECT 1")).to eq(1)
  end

  # raw_connection is Active Record's PUBLIC handoff of the PG::Connection, and
  # nothing issued on it reaches raw_execute -- so it is stamped at the handoff.
  # Without that, this write carries the stamp the connection last held: the
  # previous actor, not a NULL. DESIGN §26; sequel_correlation_spec is the same
  # property reached through Sequel.
  it "stamps a write issued on the raw connection with the current actor, not the connection's last" do
    product = create_product(price_cents: 1_000)
    other   = create_user(name: "Other Person")
    as_actor(user) { Product.where(id: product.id).update_all(price_cents: 1_100) }

    request_id = nil
    as_actor(other) do
      request_id = AuditLog::Current.request_id
      ActiveRecord::Base.connection.raw_connection
                        .exec_params("UPDATE products SET price_cents = $1 WHERE id = $2", [1_200, product.id])
    end

    change = changes_for(product).last
    expect(change.diff).to eq("price_cents" => [1_100, 1_200])
    expect(change.actor_label).to eq(other.to_label)
    expect(change.request_id).to eq(request_id)
  end

  # Nothing can be written inside an aborted transaction, so the handoff does not
  # try to stamp one. Reading transaction_status there is an ordinary thing to
  # do, and a stale stamp attempted first would turn it into
  # InFailedSqlTransaction raised out of raw_connection itself.
  it "hands out the raw connection inside an aborted transaction without trying to stamp it" do
    conn   = ActiveRecord::Base.connection
    status = nil

    acting_as(audit_identity("A", 1)) do
      ActiveRecord::Base.transaction(requires_new: true) do
        conn.execute("SELECT 1")
        begin
          conn.execute("SELECT 1/0")
        rescue ActiveRecord::StatementInvalid
          nil
        end
        status = acting_as(audit_identity("B", 2)) { conn.raw_connection.transaction_status }
        raise ActiveRecord::Rollback
      end
    end

    expect(status).to eq(PG::PQTRANS_INERROR)
    expect(conn.select_value("SELECT 1")).to eq(1)
  end

  # Nor partway through a command. While a COPY streams, the session is
  # PQTRANS_ACTIVE and accepts nothing else -- and postgres-copy-style code asks
  # for raw_connection per row. A stale stamp attempted there would be sent into
  # the middle of the COPY, fail, and abort it. The rows belong to the COPY, which
  # was issued (and stamped) under the actor who started it.
  it "does not try to stamp a session partway through a COPY" do
    conn     = ActiveRecord::Base.connection
    starter  = audit_identity("Started the COPY", 1)
    sku      = "COPY-#{SecureRandom.hex(3).upcase}"
    now      = Time.current.utc.iso8601

    acting_as(starter) do
      conn.raw_connection.copy_data(
        "COPY products (sku, name, price_cents, created_at, updated_at) FROM STDIN WITH (FORMAT csv)"
      ) do
        acting_as(audit_identity("Changed mid-COPY", 2)) do
          conn.raw_connection.put_copy_data("#{sku},Copied,700,#{now},#{now}\n")
        end
      end
    end

    copied = Product.find_by!(sku: sku)
    expect(changes_for(copied).sole.actor_label).to eq("Started the COPY")
  end

  # --------------------------------------------------------------------------
  # Transaction endings only a REAL transaction has. ROLLBACK AND CHAIN is what
  # Active Record issues to restart a parent it nested a requires_new inside
  # before the parent had written anything -- inside the fixture transaction
  # every requires_new is a savepoint, so these cannot be reached from there.
  # And PostgreSQL turns the COMMIT of an aborted transaction into a ROLLBACK
  # without raising. Rows commit here, so the group cleans up after itself, on a
  # fresh connection in case an example left the pooled one aborted.
  # --------------------------------------------------------------------------
  describe "outside any fixture transaction" do
    self.use_transactional_tests = false

    let!(:product)  { create_product(price_cents: 1_000) }
    let(:previous)  { audit_identity("Previous request", 101) }
    let(:current)   { audit_identity("Current request", 202) }
    let(:conn)      { ActiveRecord::Base.connection }

    after do
      ActiveRecord::Base.connection_pool.disconnect!
      Product.where(id: product.id).delete_all
      AuditLog::Change.where(record_type: "Product", record_id: product.id).delete_all
    end

    def last_change
      changes_for(product).last
    end

    # create_or_find_by's shape. The stamp for this request is written inside the
    # transaction; the nested insert fails; Active Record restarts the parent with
    # ROLLBACK AND CHAIN, which reverts the stamp to the previous request's. A memo
    # still claiming this request would skip the next stamp and credit the update
    # to whoever used the connection before.
    it "forgets the stamp a ROLLBACK AND CHAIN reverted, so the next write re-stamps" do
      acting_as(previous) { Product.where(id: product.id).update_all(price_cents: 1_100) }

      acting_as(current) do
        Product.transaction do
          begin
            Product.transaction(requires_new: true) do
              Product.insert!({ sku: product.sku, name: "Duplicate", price_cents: 1 })
            end
          rescue ActiveRecord::RecordNotUnique
            nil
          end
          Product.where(id: product.id).update_all(price_cents: 1_200)
        end
      end

      expect(last_change.diff).to eq("price_cents" => [1_100, 1_200])
      expect(last_change.actor_label).to eq("Current request")
    end

    # The restart is a rollback too, and is never stamped -- otherwise the stale
    # stamp in front of it runs in the aborted transaction, fails, and the
    # ROLLBACK AND CHAIN is never sent.
    it "restarts for real, and reports the real error, when the actor changed back first" do
      error = nil

      acting_as(previous) do
        ActiveRecord::Base.transaction do
          begin
            ActiveRecord::Base.transaction(requires_new: true) do
              acting_as(current) { conn.execute("SELECT 1/0") }
            end
          rescue ActiveRecord::StatementInvalid => e
            error = e
          end

          expect(conn.select_value("SELECT 1")).to eq(1)
        end
      end

      expect(error.cause).to be_a(PG::DivisionByZero)
    end

    # PostgreSQL answers the COMMIT of an aborted transaction with ROLLBACK and no
    # error, so Active Record believes it committed while the stamp written inside
    # was reverted. The memo has to go there too.
    it "forgets the stamp an aborted transaction's COMMIT silently rolled back" do
      acting_as(previous) { Product.where(id: product.id).update_all(price_cents: 1_100) }

      acting_as(current) do
        ActiveRecord::Base.transaction do
          conn.execute("SELECT 1")
          begin
            conn.execute("SELECT 1/0")
          rescue ActiveRecord::StatementInvalid
            nil
          end
        end
        Product.where(id: product.id).update_all(price_cents: 1_200)
      end

      expect(last_change.diff).to eq("price_cents" => [1_100, 1_200])
      expect(last_change.actor_label).to eq("Current request")
    end

    # The handoff can itself reconnect: a connection checked out after idling
    # past verify_timeout is verified first, and a dead backend is replaced --
    # with a fresh session carrying no stamp. So the stamp is taken AFTER
    # raw_connection's own work, on the session actually handed over. Stamping
    # first saw a matching memo, skipped, and handed out the unstamped session.
    it "stamps the session a raw_connection handoff reconnected to" do
      acting_as(current) do
        conn.execute("SELECT 1")
        pid = conn.select_value("SELECT pg_backend_pid()")

        other = ActiveRecord::Base.connection_pool.checkout
        other.execute("SELECT pg_terminate_backend(#{pid})")
        ActiveRecord::Base.connection_pool.checkin(other)

        # What a checkout after a long idle looks like to the adapter.
        conn.clean!
        conn.instance_variable_set(:@last_activity, nil)

        conn.raw_connection.exec_params("UPDATE products SET price_cents = $1 WHERE id = $2", [1_200, product.id])
      end

      expect(last_change.actor_label).to eq("Current request")
      expect(last_change.request_id).to eq(current[:request_id])
    end

    # A disconnected adapter has no session for the memo to describe. Reused, it
    # reconnects lazily INSIDE the next statement -- after that statement's stamp
    # check has already trusted the memo -- so the memo goes when the session does.
    it "forgets the stamp on disconnect!, so a reused adapter's new session is stamped" do
      acting_as(current) do
        Product.where(id: product.id).update_all(price_cents: 1_100)
        conn.disconnect!
        Product.where(id: product.id).update_all(price_cents: 1_200)
      end

      expect(last_change.diff).to eq("price_cents" => [1_100, 1_200])
      expect(last_change.actor_label).to eq("Current request")
    end
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

