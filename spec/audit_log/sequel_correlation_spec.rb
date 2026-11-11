# frozen_string_literal: true

require "rails_helper"
require "sequel/core"

# Sequel through sequel-activerecord_connection, which is how rodauth-rails runs
# every Rodauth query. The extension reuses Active Record's own PG::Connection --
# no pool of its own, and Sequel transactions ARE Active Record transactions --
# but its statements go straight to `async_exec` on that connection and never
# reach the adapter's `raw_execute`, which is where AuditLog::TransactionStamp
# stamps Active Record's statements. What does reach the adapter is the
# extension's call to its PUBLIC `raw_connection`, once per Sequel synchronize --
# and TransactionStamp stamps there too. This library never names Sequel; these
# examples are what prove the extension still takes that route. DESIGN §26.
#
# Layer 1 is not in question: the trigger fires whoever issues the statement.
# What these examples pin is that the row it writes names the RIGHT actor and
# request_id, because the failure here is not a NULL. The stamp is session-level,
# so an unstamped statement carries whatever the pooled connection last held --
# an earlier unit of work's identity -- and the change is credited to the wrong
# person, silently.
RSpec.describe "correlation through Sequel (sequel-activerecord_connection)" do
  # Exactly what rodauth-rails generates into app/misc/rodauth_main.rb. Nothing
  # audit_log-specific is passed, and that is part of what is under test: a host
  # that adds Rodauth must not have to remember a second step to stay correlated.
  def build_sequel_db(model = ActiveRecord::Base)
    Sequel.postgres(extensions: :activerecord_connection, keep_reference: false)
          .tap { |db| db.activerecord_model = model }
  end

  def stamp_of(identity)
    identity.values_at(:request_id, :actor_type, :actor_id, :actor_label).map(&:to_s)
  end

  def memo(conn = ActiveRecord::Base.connection)
    conn.instance_variable_get(:@audit_stamp)
  end

  # Round trips spent stamping. The extension instruments its own statements as
  # sql.active_record too, under the name "Sequel", so filtering on the stamp's
  # name counts the stamp and nothing else.
  def count_stamps(&block)
    count_queries(named: AuditLog::Context::STAMP_QUERY_NAME, &block)
  end

  let(:db)  { build_sequel_db }
  let(:a)   { audit_identity("Actor A", 101) }
  let(:b)   { audit_identity("Actor B", 202) }

  def expect_attributed_to(change, who)
    expect(change.actor_label).to eq(who[:actor_label])
    expect(change.actor_id).to eq(who[:actor_id])
    expect(change.request_id).to eq(who[:request_id])
  end

  # --------------------------------------------------------------------------
  # As production runs it: no fixture transaction around the example, so "outside
  # a transaction" means outside one, BEGIN and ROLLBACK are real rather than
  # savepoints, and connections are leased through with_connection exactly as the
  # extension leases them on Rails >= 7.2.
  #
  # The price is that the rows commit, so this group cleans up after itself.
  # --------------------------------------------------------------------------
  describe "outside any fixture transaction" do
    self.use_transactional_tests = false

    let!(:product) { create_product(price_cents: 1_000) }

    # On a FRESH connection. A regression in this file's own subject leaves the
    # pooled one inside an aborted transaction -- it has happened -- and a cleanup
    # that dies there leaves committed rows behind that fail unrelated specs on
    # every run after, until somebody deletes them by hand.
    after do
      ActiveRecord::Base.connection_pool.disconnect!

      ids = Product.where(sku: product.sku).or(Product.where("sku LIKE 'SEQ-%'")).pluck(:id)
      Product.where(id: ids).delete_all
      AuditLog::Change.where(record_type: "Product", record_id: ids).delete_all
    end

    # The headline case, and the shape of the real one: Rodauth's lockout feature
    # increments the failed-login counter with a bare UPDATE ... RETURNING, and
    # nothing earlier in that request has touched Active Record.
    it "stamps a bare Sequel UPDATE ... RETURNING with the CURRENT actor, not the connection's last" do
      acting_as(a) { Product.where(id: product.id).update_all(price_cents: 1_100) }
      expect(memo).to eq(stamp_of(a))

      acting_as(b) do
        db[:products].where(id: product.id)
                     .returning(:price_cents)
                     .update(price_cents: Sequel[:price_cents] + 1)
      end

      change = changes_for(product).last
      expect(change.diff).to eq("price_cents" => [1_100, 1_101])
      expect_attributed_to(change, b)
    end

    # A reconnect discards session settings, so a connection whose first
    # statement in the unit of work is a Sequel write has nothing on it at all.
    it "stamps a cold connection whose first statement is a Sequel write" do
      ActiveRecord::Base.connection_pool.disconnect!

      sku = "SEQ-#{SecureRandom.hex(3).upcase}"
      acting_as(b) do
        db[:products].insert(sku: sku, name: "Inserted by Sequel", price_cents: 500,
                             created_at: Time.current, updated_at: Time.current)
      end

      inserted = Product.find_by!(sku: sku)
      expect_attributed_to(changes_for(inserted).sole, b)
    end

    # Passed before raw_connection was stamped, because the extension delegates
    # begin_transaction to Active Record and BEGIN goes through raw_execute. Now
    # the stamp lands earlier, when the transaction's own synchronize takes the raw
    # connection, so this pins the OUTCOME and neither route. That the extension delegates its
    # transaction control to Active Record at all is pinned by the rollback
    # examples below, which depend on it.
    it "stamps a Sequel transaction with the current actor" do
      acting_as(a) { Product.where(id: product.id).update_all(price_cents: 1_100) }

      acting_as(b) do
        db.transaction { db[:products].where(id: product.id).update(price_cents: 1_200) }
      end

      expect_attributed_to(changes_for(product).last, b)
    end

    # Rodauth's after_login hook is where a host sets the actor, and it runs in
    # the middle of the request -- and of Rodauth's transaction.
    it "applies an actor change made inside a Sequel transaction to the next Sequel statement" do
      acting_as(a) do
        db.transaction do
          db[:products].where(id: product.id).update(price_cents: 1_100)
          acting_as(b) { db[:products].where(id: product.id).update(price_cents: 1_200) }
        end
      end

      first, second = changes_for(product).last(2)
      expect_attributed_to(first, a)
      expect_attributed_to(second, b)
    end

    # A session-level SET inside a transaction is reverted by its ROLLBACK, while
    # the connection's memo would still claim it. Sequel's rollback reaches
    # TransactionStamp#exec_rollback_db_transaction through Active Record; this
    # proves that, and that the next Sequel statement acts on it.
    it "clears the memo on a Sequel ROLLBACK, so the next Sequel statement re-stamps" do
      acting_as(a) do
        Product.where(id: product.id).update_all(price_cents: 1_100)

        db.transaction(rollback: :always) do
          acting_as(b) { db[:products].where(id: product.id).update(price_cents: 1_200) }
        end
      end
      # The server reverted to A's stamp. A memo still saying B would make the
      # next statement under B skip the round trip and be credited to A.
      expect(memo).to be_nil

      acting_as(b) { db[:products].where(id: product.id).update(price_cents: 1_300) }

      change = changes_for(product).last
      expect(change.diff).to eq("price_cents" => [1_100, 1_300])
      expect_attributed_to(change, b)
    end

    # Found in review, and introduced by stamping on this path at all. The stamp
    # for B is written INSIDE the transaction; the failing statement aborts it;
    # Current unwinds back to A before Sequel rolls back. Had the ROLLBACK stamped
    # first -- A against a memo saying B -- that SELECT would fail in the aborted
    # transaction, the ROLLBACK would never be sent, Sequel would swallow the
    # failure, and the pooled connection would be handed to the next request
    # still inside an aborted transaction.
    it "rolls back for real after a failed Sequel statement whose actor change unwound first" do
      expect do
        acting_as(a) do
          db.transaction do
            db.get(1)
            acting_as(b) { db.get(Sequel.lit("1/0")) }
          end
        end
      end.to raise_error(Sequel::DatabaseError, /division by zero/)

      expect(db.get(1)).to eq(1)
    end

    # The same thing one level down, in the exact shape Rodauth's
    # raises_uniqueness_violation? uses: a savepoint around a statement that may
    # fail, rescued, and the outer transaction carrying on.
    it "keeps a rescued savepoint: :only failure from aborting the enclosing Sequel transaction" do
      result = acting_as(a) do
        db.transaction do
          begin
            db.transaction(savepoint: :only) { acting_as(b) { db.get(Sequel.lit("1/0")) } }
          rescue Sequel::DatabaseError
            nil
          end
          db.get(42)
        end
      end

      expect(result).to eq(42)
    end

    # Nothing can be written once a transaction has aborted, so the handout does
    # not attempt a stamp there. Had it tried -- B against a memo saying A -- the
    # stamp's own SELECT would have failed first and the caller would get an
    # Active Record exception out of Sequel, where it reasonably rescues
    # Sequel::DatabaseError.
    it "lets a Sequel statement in an aborted transaction fail with Sequel's own error" do
      expect do
        acting_as(a) do
          db.transaction do
            begin
              db.get(Sequel.lit("1/0"))
            rescue Sequel::DatabaseError
              nil
            end
            acting_as(b) { db.get(1) }
          end
        end
      end.to raise_error(Sequel::DatabaseError, /current transaction is aborted/)

      expect(db.get(1)).to eq(1)
    end

    it "clears the memo on a Sequel savepoint rollback, so the next Sequel statement re-stamps" do
      acting_as(a) do
        db.transaction do
          db[:products].where(id: product.id).update(price_cents: 1_100)

          db.transaction(savepoint: true, rollback: :always) do
            acting_as(b) { db[:products].where(id: product.id).update(price_cents: 1_200) }
          end
          expect(memo).to be_nil

          acting_as(b) { db[:products].where(id: product.id).update(price_cents: 1_300) }
        end
      end

      first, second = changes_for(product).last(2)
      expect_attributed_to(first, a)
      expect(second.diff).to eq("price_cents" => [1_100, 1_300])
      expect_attributed_to(second, b)
    end

    # The connection to stamp is the one the extension leases, and on Rails >= 7.2
    # that is not necessarily ActiveRecord::Base.connection: `activerecord_model`
    # is configurable. Stamping inside raw_connection gets this right by
    # construction -- it stamps whichever adapter is handing its connection over.
    #
    # Here the Sequel database runs on a second pool, named "secondary", and only
    # that name is correlated. An implementation that stamped the primary
    # connection would stamp nothing (primary is not correlated) and the row would
    # land with a NULL actor.
    it "stamps the connection of the model Sequel is configured with, not ActiveRecord::Base's" do
      stub_const("SecondaryRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      SecondaryRecord.establish_connection(
        ActiveRecord::DatabaseConfigurations::HashConfig.new(
          "test", "secondary", ActiveRecord::Base.connection_db_config.configuration_hash
        )
      )
      allow(AuditLog.config).to receive(:correlated_connections).and_return(%w[secondary])

      secondary_db = build_sequel_db(SecondaryRecord)
      acting_as(b) { secondary_db[:products].where(id: product.id).update(price_cents: 1_200) }

      expect_attributed_to(changes_for(product).last, b)
    ensure
      SecondaryRecord.remove_connection if defined?(SecondaryRecord)
    end

    # OUT OF SCOPE, and pinned so the documentation of it stays true: a Sequel
    # database with its OWN connections (no activerecord_connection extension) is
    # a different PostgreSQL session that nothing stamps. Its writes are audited
    # -- the trigger cannot be bypassed -- and land uncorrelated, exactly like any
    # other out-of-band write (DESIGN §9).
    it "still audits a Sequel database with its own connections, uncorrelated" do
      settings = ActiveRecord::Base.connection_db_config.configuration_hash
      own = Sequel.connect(adapter: :postgres, host: settings[:host], port: settings[:port],
                           user: settings[:username], password: settings[:password],
                           database: settings[:database], keep_reference: false)

      acting_as(b) { own[:products].where(id: product.id).update(price_cents: 1_200) }

      change = changes_for(product).last
      expect(change.diff).to eq("price_cents" => [1_000, 1_200])
      expect(change.request_id).to be_nil
      expect(change.actor_label).to be_nil
    ensure
      own&.disconnect
    end
  end

  # --------------------------------------------------------------------------
  # Inside the fixture transaction, where the connection is pinned and its lock is
  # a real monitor rather than ActiveSupport's NullLock.
  # --------------------------------------------------------------------------
  describe "with the adapter lock held by the extension" do
    let(:product) { create_product(price_cents: 1_000) }

    # The extension holds `activerecord_connection.lock` (and, on Rails 8.0, the
    # load interlock's permit_concurrent_loads) while it calls raw_connection.
    # Stamping there calls back into the adapter's exec_query, which re-enters
    # the same lock. That must be re-entrant rather than a
    # deadlock -- and it must be tested against a REAL monitor, which only the
    # pinned fixture connection has. Outside fixtures the lock is a NullLock and
    # this example would prove nothing.
    #
    # And it must actually STAMP from in there. `product` is created first, under
    # no actor, so the memo is stale when the Sequel statement arrives; a lazy
    # `let` evaluated inside acting_as(b) would have stamped B through Active
    # Record first and left the hook nothing to do, which is how an earlier
    # version of this example proved nothing at all.
    it "re-enters the adapter from inside the extension's lock without deadlocking" do
      expect(ActiveRecord::Base.connection.lock).not_to equal(ActiveSupport::Concurrency::NullLock)
      product

      stamps = Timeout.timeout(5) do
        count_stamps do
          acting_as(b) { db[:products].where(id: product.id).update(price_cents: 1_200) }
        end
      end

      expect(stamps).to eq(1)
      expect_attributed_to(changes_for(product).last, b)
    end

    # "One Ruby comparison per statement, a round trip only when stale" -- the
    # cost profile raw_execute has, held to on the Sequel path.
    it "spends one stamp round trip per unit of work, however many Sequel statements it issues" do
      product # created, and stamped, outside the counted blocks

      first = count_stamps do
        acting_as(b) do
          3.times { |i| db[:products].where(id: product.id).update(price_cents: 1_100 + i) }
          db[:products].where(id: product.id).get(:price_cents)
        end
      end
      expect(first).to eq(1)

      # A unit of work that already stamped the connection through Active Record
      # costs the Sequel statements after it nothing at all.
      mixed = count_stamps do
        acting_as(a) do
          Product.where(id: product.id).update_all(price_cents: 1_500)
          db[:products].where(id: product.id).update(price_cents: 1_600)
        end
      end
      expect(mixed).to eq(1)
    end

    # correlated_connections gates who pays for correlation, on the Sequel path as
    # on every other. The write is still audited (correlation_spec proves that for
    # Active Record); it simply costs no round trip.
    it "does not stamp a connection that correlated_connections does not name" do
      product
      allow(AuditLog.config).to receive(:correlated_connections).and_return([])

      stamps = count_stamps do
        acting_as(b) { db[:products].where(id: product.id).update(price_cents: 1_200) }
      end

      expect(stamps).to eq(0)
      expect(changes_for(product).last.diff).to eq("price_cents" => [1_000, 1_200])
    end
  end

  # --------------------------------------------------------------------------
  # What the library knows about Sequel: nothing, and that is the design.
  # --------------------------------------------------------------------------
  describe "the library's knowledge of Sequel" do
    # Same argument as pagination_spec's pagy example: a dependency added here
    # fails nothing else in this suite, and fails an app that never asked for
    # Sequel six months from now. DESIGN §2.4.
    it "brings no Sequel dependency into the host app" do
      spec = Gem::Specification.load(File.expand_path("../../audit_log.gemspec", __dir__))

      expect(spec.dependencies.map(&:name)).not_to include("sequel", "sequel-activerecord_connection")
    end

    # A Sequel-specific hook was built first and replaced (DESIGN §26): it loaded
    # Sequel at boot in any host that bundled it, called a private method of the
    # extension, and covered one library where raw_connection covers every
    # raw-connection writer. Comments may say "Sequel"; code may not. This suite
    # loads Sequel for this file, so nothing else in it would notice a reference.
    #
    # Every file, not only *.rb: a rake task or a generator template can require
    # a gem just as well. And the constant at all, not only `Sequel::` -- the
    # replaced hook was gated on `Gem.loaded_specs["sequel-activerecord_connection"]`,
    # and `defined?(::Sequel)` is the next obvious spelling of the same coupling.
    it "names no Sequel constant and loads, requires or checks for no Sequel gem" do
      sources = Dir[File.join(AuditLog::GEM_ROOT, "{lib,app}/**/*")].select { |path| File.file?(path) }
      expect(sources.grep(%r{/lib/audit_log/tasks/.+\.rake\z})).not_to be_empty

      offenders = sources.select do |path|
        File.readlines(path).reject { |line| line.lstrip.start_with?("#") }
            .any? { |line| line.match?(/\bSequel\b|["']sequel/) }
      end

      expect(offenders).to be_empty
    end
  end
end
