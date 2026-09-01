# frozen_string_literal: true

require "rails_helper"

# Host-defined facets, both halves. DESIGN §23.
#
# THE PROPERTY THIS FILE DEFENDS is the one the rest of the suite defends from
# other angles: nothing goes missing without saying so. A faceted feed is the one
# screen in this library that legitimately returns LESS than the log holds, so
# every limit has to be a stated one rather than a discovered one -- and the two
# halves have to cover each other's holes, or "all activity for customer 5" omits
# exactly the writes an auditor scrutinises most.
#
# spec/dummy declares facets on `orders` ALONE (customer_id, created_by_id,
# status) and on four registry entries. Every other table deliberately declares
# none, which is what keeps the "a table that declares none pays nothing" claim
# under test rather than merely asserted.
RSpec.describe "dimensions" do
  let(:staff)    { create_user(name: "Raj Patel", role: "staff") }
  let(:customer) { create_customer(name: "Northwind") }

  def create_order(customer: nil, by: nil, **attrs)
    Order.create!(customer: customer || self.customer, created_by: by || staff, **attrs)
  end

  # ---------------------------------------------------------------- the trigger
  describe "the row-derived half" do
    it "records the declared columns as jsonb TEXT, not as numbers" do
      order = as_actor(staff) { create_order }

      # Text is the stored shape on purpose: {"customer_id": 5} and
      # {"customer_id": "5"} do not match under @>, and the symptom of getting it
      # wrong is an empty screen rather than an error.
      expect(changes_for(order).first.dimensions).to eq(
        "customer_id" => customer.id.to_s, "created_by_id" => staff.id.to_s, "status" => "draft"
      )
    end

    it "declares nothing for a table that declares nothing, so the partial index excludes it" do
      as_actor(staff) { create_order }

      expect(AuditLog::Change.where.not(record_type: "Order").pluck(:dimensions).uniq).to eq([nil])
    end

    # THE ENTIRE REASON THE ROW-DERIVED HALF EXISTS. update_all runs no Active
    # Record callback, so an application-level facet mechanism records nothing
    # here -- and a bulk status change is exactly the write an auditor asks about.
    it "records facets for a write no callback ever sees" do
      order = as_actor(staff) { create_order }
      Order.where(id: order.id).update_all(status: "approved")

      expect(changes_for(order).last.dimensions).to include("status" => "approved")
    end

    it "reads OLD on a delete, so a deleted record's final facet is how it is found" do
      order = as_actor(staff) { create_order }
      as_actor(staff) { order.update!(status: "cancelled") }
      as_actor(staff) { order.destroy! }

      deleted = changes_for(order).find(&:deleted?)
      expect(deleted.dimensions).to include("status" => "cancelled",
                                            "customer_id" => customer.id.to_s)
    end

    # NULLS ARE SKIPPED, and the key is absent rather than JSON null. Storing an
    # explicit null appears to buy the negative query and does not: absence here
    # is already overloaded between "the FK was null" and "the row predates the
    # declaration", so the negative query carries a permanent asterisk either way.
    it "omits a key whose column was NULL rather than storing a JSON null" do
      order = as_actor(staff) { Order.create!(customer: customer, created_by: nil) }

      dims = changes_for(order).first.dimensions
      expect(dims).not_to have_key("created_by_id")
      expect(dims).to include("customer_id" => customer.id.to_s)
    end

    # A DEPARTURE IS NOT CAPTURED -- the row is filed under the value held AFTER
    # the change. Stated rather than discovered, because the feed simply stops.
    it "files a change under the value held after it, so the old facet's feed ends there" do
      order = as_actor(staff) { create_order }
      as_actor(staff) { order.update!(status: "submitted") }

      moved = changes_for(order).last
      expect(moved.dimensions).to include("status" => "submitted")
      # Nothing is lost from the RECORD: the transition is an ordinary field
      # change, and `diff` holds [old, new] as a real jsonb array.
      expect(moved.diff["status"]).to eq(%w[draft submitted])
    end
  end

  # ------------------------------------------------------------------- validation
  # THE ONLY ENFORCEMENT IN THE WHOLE FEATURE, and it is at migration time.
  describe "declaring a column that does not exist" do
    def migrate(*facets)
      migration = Class.new(ActiveRecord::Migration::Current) do
        cattr_accessor(:facets) { [] }
        def change = attach_audit_trigger(:products, model: "Product", dimensions: self.class.facets)
      end
      migration.facets = facets
      migration.new.tap { |m| m.verbose = false }.migrate(:up)
    end

    it "raises in the migration rather than recording nothing forever" do
      expect { migrate(:deparment_id) }.to raise_error(ArgumentError, /deparment_id.*not a column/m)
    end

    it "names the columns the table does have, so the typo is obvious" do
      expect { migrate(:nope) }.to raise_error(ArgumentError, /price_cents/)
    end
  end

  # ------------------------------------------------------------ the events half
  describe "the app-supplied half" do
    it "lifts a declared key out of the payload and leaves it in metadata" do
      order = as_actor(staff) { create_order }
      as_actor(staff) { order.submit! }

      event = AuditLog::Event.find_by(action: "order.submitted")
      # COPIED, NOT MOVED. metadata is evidence and is emptied by Redaction;
      # dimensions is structure and is not. That duplication is the whole reason
      # the column exists rather than being a metadata key.
      expect(event.dimensions).to include("customer_id" => customer.id.to_s)
      expect(event.metadata["customer_id"]).to eq(customer.id)
    end

    it "lifts a facet the block computed, not only an eagerly-passed one" do
      order = as_actor(staff) { create_order }

      as_actor(staff) do
        AuditLog.audited("order.submitted", on: Order,
                         order_id: order.id, reference: order.reference,
                         customer_name: customer.name) do |audit|
          order.update!(status: "submitted")
          # Lifting happens AFTER the payload is assembled, which is what makes
          # the two-slot design work here for free -- a reserved `dimensions:`
          # keyword on the emit would have been eager-only.
          audit[:customer_id] = order.customer_id
          audit[:line_count]  = 0
          audit[:total_cents] = 0
        end
      end

      expect(AuditLog::Event.find_by(action: "order.submitted").dimensions)
        .to include("customer_id" => customer.id.to_s)
    end

    it "does not require a facet it declares" do
      # order.shipped declares customer_id as a facet and does NOT require it.
      # Loose by default: an emit omitting it writes the event with no facet and
      # raises nothing.
      expect {
        as_actor(staff) do
          AuditLog.notify("order.shipped", order_id: 1, reference: "SO-1",
                                           carrier: "UPS", tracking_number: "1Z")
        end
      }.not_to raise_error

      expect(AuditLog::Event.find_by(action: "order.shipped").dimensions)
        .not_to have_key("customer_id")
    end

    describe "config.default_dimensions" do
      it "applies to every event without a call site repeating it" do
        as_actor(staff) { AuditLog.notify("customer.created", customer_id: customer.id, name: "N") }

        expect(AuditLog::Event.last.dimensions).to include("app_version" => "2026.09.1")
      end

      it "is merged UNDER the declared keys, so a call site wins on overlap" do
        allow(AuditLog.config).to receive(:default_dimensions)
          .and_return(-> { { customer_id: "ambient-loses" } })

        as_actor(staff) { AuditLog.notify("customer.created", customer_id: customer.id, name: "N") }

        expect(AuditLog::Event.last.dimensions["customer_id"]).to eq(customer.id.to_s)
      end

      # IT NEVER RE-RAISES, and the precedent split is principled rather than
      # arbitrary: `requires:` and raise_on_subscriber_error roll the transaction
      # back because they protect the TRAIL, LabelResolver logs because it is
      # display. A facet is a convenience, so it follows LabelResolver. Rolling
      # back an approved order because an app-version lookup raised would be
      # indefensible.
      it "stores the event anyway when the lambda raises" do
        allow(AuditLog.config).to receive(:default_dimensions)
          .and_return(-> { raise "the version endpoint is down" })

        expect {
          as_actor(staff) { AuditLog.notify("customer.created", customer_id: customer.id, name: "N") }
        }.to change(AuditLog::Event, :count).by(1)

        expect(AuditLog::Event.last.dimensions).to eq("customer_id" => customer.id.to_s)
      end

      # Computed ONCE PER UNIT OF WORK, which is available precisely because the
      # lambda takes no arguments -- and is also the guarantee that two events in
      # one unit of work cannot disagree about the tenant.
      it "is computed once per unit of work, not once per event" do
        calls = 0
        allow(AuditLog.config).to receive(:default_dimensions)
          .and_return(-> { calls += 1; { app_version: "x" } })

        as_actor(staff) do
          AuditLog.notify("customer.created", customer_id: customer.id, name: "N")
          AuditLog.notify("customer.updated", customer_id: customer.id, name: "N")
        end

        expect(calls).to eq(1)
        expect(AuditLog::Event.pluck(:dimensions).map { |d| d["app_version"] }).to eq(%w[x x])
      end
    end
  end

  # ------------------------------------------------------------- where_dimensions
  describe "AuditLog::Record.where_dimensions" do
    before do
      @order = as_actor(staff) { create_order }
      as_actor(staff) { @order.update!(status: "submitted") }
    end

    # THE ONE NORMALISATION POINT. A caller has an Integer id in hand; the column
    # stores text. Getting this wrong anywhere else is a silent empty screen.
    it "normalises an Integer value to the stored text" do
      expect(AuditLog::Change.where_dimensions(customer_id: customer.id).count).to eq(2)
      expect(AuditLog::Change.where_dimensions(customer_id: customer.id.to_s).count).to eq(2)
    end

    it "narrows on a conjunction rather than needing an index per combination" do
      expect(
        AuditLog::Change.where_dimensions(customer_id: customer.id, status: "submitted").count
      ).to eq(1)
    end

    it "is a no-op for an empty set, so an unfiltered screen composes" do
      expect(AuditLog::Change.where_dimensions({}).count).to eq(AuditLog::Change.count)
      expect(AuditLog::Change.where_dimensions(customer_id: nil).count).to eq(AuditLog::Change.count)
    end

    it "works on both tables through one implementation" do
      as_actor(staff) { @order.submit! }

      expect(AuditLog::Event.where_dimensions(customer_id: customer.id).count).to eq(1)
    end

    # A conjunction has to fit on ONE ROW, because @> matches a single jsonb
    # value. Stated in DESIGN, stated in the README, and pinned here so it cannot
    # quietly start behaving like a cross-table intersection.
    it "matches nothing across facets that live on different tables" do
      expect(
        AuditLog::Change.where_dimensions(customer_id: customer.id, product_id: 1).count
      ).to be_zero
    end
  end

  # ----------------------------------------------------------- DimensionTimeline
  describe "AuditLog::DimensionTimeline" do
    def units(timeline) = timeline.activity_keys.to_a

    it "is bounded by default, and says so" do
      timeline = AuditLog::DimensionTimeline.new(dimensions: { customer_id: 1 })

      expect(timeline).to be_bounded
      expect(timeline.scope_description).to match(/customer_id = 1 — from \d{4}-\d\d-\d\d/)
    end

    # `range: nil` PASSED EXPLICITLY IS UNBOUNDED. The default lives in the
    # signature rather than behind a `||=` precisely so this distinction survives.
    it "is unbounded when a caller passes range: nil explicitly" do
      timeline = AuditLog::DimensionTimeline.new(dimensions: { customer_id: 1 }, range: nil)

      expect(timeline).not_to be_bounded
      expect(timeline.scope_description).to include("across all retained history")
    end

    it "yields one activity per unit of work, not one per row" do
      order = as_actor(staff) do
        create_order(line_items_attributes: [{ product_id: create_product.id, quantity: 2 }])
      end

      keys = units(AuditLog::DimensionTimeline.new(dimensions: { customer_id: customer.id }))
      expect(keys.size).to eq(1)

      activity = AuditLog::DimensionTimeline
                 .new(dimensions: { customer_id: customer.id }).activities(keys).first
      expect(activity.record_type).to eq("Order")
      expect(activity.record_id.to_s).to eq(order.id.to_s)
      expect(activity.also_touched.map(&:type)).to include("LineItem")
    end

    # THE EVENTS LEG IS NOT OPTIONAL, and this is the case that proves it here:
    # the job's writes land in `shipments`, which declares no facets, so a
    # changes-only feed would report the order's status flip and lose the shipment
    # beside it. The event carries customer_id for the whole unit of work.
    it "includes a unit whose change rows carry no facet, matched through its event" do
      order = as_actor(staff) { create_order }
      job = as_actor(staff) { OrderFulfillmentJob.new(order).tap(&:serialize) }
      ActiveJob::Base.execute(job.serialize)
      AuditLog::Current.reset

      shipped = AuditLog::Event.find_by(action: "order.shipped")
      expect(shipped.dimensions).to include("customer_id" => customer.id.to_s)
      expect(
        AuditLog::Change.where(request_id: shipped.request_id, record_type: "Shipment")
                        .pluck(:dimensions)
      ).to eq([nil])

      keys = units(AuditLog::DimensionTimeline.new(dimensions: { customer_id: customer.id }))
      expect(keys.map(&:request_id)).to include(shipped.request_id)
    end

    # An out-of-band write has no request_id and correlates to nothing, so it gets
    # a synthetic key. Without one, every uncorrelated write in the log collapses
    # into a single NULL group -- and the row-wise keyset predicate then evaluates
    # to NULL and the feed goes blank after page one, silently.
    it "includes an out-of-band write as its own unit" do
      order = as_actor(staff) { create_order }
      AuditLog::Current.reset
      Order.where(id: order.id).update_all(notes: "swept by a rake task")

      keys = units(AuditLog::DimensionTimeline.new(dimensions: { customer_id: customer.id }))
      expect(keys.select(&:out_of_band?).size).to eq(1)
    end

    it "does not leak one facet's activity into another's" do
      other = create_customer(name: "Bluefin")
      as_actor(staff) { create_order }
      as_actor(staff) { create_order(customer: other) }

      expect(units(AuditLog::DimensionTimeline.new(dimensions: { customer_id: customer.id })).size)
        .to eq(1)
      expect(units(AuditLog::DimensionTimeline.new(dimensions: { customer_id: other.id })).size)
        .to eq(1)
    end

    # NOT RETROACTIVE. A row written before the facet was declared carries NULL,
    # and `@>` can never match it. This is the limit most likely to be filed as a
    # bug, so it is pinned as behaviour.
    it "cannot match a row that predates the declaration" do
      order = as_actor(staff) { create_order }
      # What a pre-adoption row looks like. Written with raw SQL because the audit
      # models are append-only from the application's side (readonly? = persisted?),
      # which is exactly the property this library relies on everywhere else.
      row = changes_for(order).first
      AuditLog::Change.connection.execute(
        "UPDATE audit_changes SET dimensions = NULL WHERE id = #{row.id}"
      )

      expect(AuditLog::Change.where_dimensions(customer_id: customer.id).count)
        .to eq(changes_for(order).count - 1)
    end

    # NEVER `all`. A cleared filter must not become a scan of the entire audit
    # log dressed up as a result.
    it "returns nothing rather than everything when no facet survives" do
      as_actor(staff) { create_order }
      timeline = AuditLog::DimensionTimeline.new(dimensions: { customer_id: "" })

      expect(timeline).to be_unfiltered
      expect(units(timeline)).to be_empty
    end

    # The published contract: the same Activity a record timeline yields, so
    # anything a host already renders for one works here unchanged.
    it "yields the same value objects a record timeline does" do
      order = as_actor(staff) { create_order }
      as_actor(staff) { order.submit! }

      timeline = AuditLog::DimensionTimeline.new(dimensions: { customer_id: customer.id })
      activity = timeline.activities(units(timeline)).find(&:narrative?)

      expect(activity).to be_a(AuditLog::Timeline::Activity)
      expect(activity.headline).to include("Submitted order")
      expect(activity.field_changes.map(&:column)).to include("status")
      expect(activity.actor.display).to eq(staff.to_label)
    end

    # Keyset paging over the same relation every other browse screen uses -- and
    # the same three ActivityKey requirements, so a unit is neither dropped nor
    # repeated across a page boundary.
    it "pages by keyset without dropping or repeating a unit" do
      orders = Array.new(6) { as_actor(staff) { create_order } }
      timeline = AuditLog::DimensionTimeline.new(dimensions: { customer_id: customer.id })

      seen, cursor = [], nil
      4.times do
        page = AuditLog::Pagination::Page.new(timeline.activity_keys, cursor: cursor, limit: 2)
        break if page.records.empty?

        seen.concat(page.records.map(&:key))
        cursor = page.next
        break if cursor.nil?
      end

      expect(seen.uniq.size).to eq(orders.size)
    end

    describe "#older_than_window?" do
      # It has to swap with the predicates, or it answers a DIFFERENT question
      # from the page above it -- reporting older history about the whole log
      # while the screen is filtered by facet.
      it "asks about the facet, not about the whole log" do
        old_order = as_actor(staff) { create_order }
        changes_for(old_order).update_all(occurred_at: 90.days.ago)

        as_actor(staff) { create_order(customer: create_customer(name: "Other")) }

        timeline = AuditLog::DimensionTimeline.new(dimensions: { customer_id: customer.id })
        expect(timeline.older_than_window?).to be true

        elsewhere = AuditLog::DimensionTimeline.new(dimensions: { customer_id: 999_999 })
        expect(elsewhere.older_than_window?).to be false
      end
    end
  end

  # ------------------------------------------------------------------- the index
  describe "storage" do
    let(:conn) { ActiveRecord::Base.connection }

    # The predicate is what keeps the index proportional to ADOPTION rather than
    # to table size. Without it every row of every non-adopting application enters
    # one enormous shared posting list (GIN records a placeholder for a NULL
    # value), serving a query nobody in that application can ask.
    it "indexes both tables with a PARTIAL jsonb_path_ops GIN" do
      %w[audit_events audit_changes].each do |table|
        definition = conn.select_value(<<~SQL)
          SELECT indexdef FROM pg_indexes
           WHERE schemaname = current_schema() AND indexname = '#{table}_dimensions_idx'
        SQL

        expect(definition).to include("USING gin (dimensions jsonb_path_ops)")
        expect(definition).to include("WHERE (dimensions IS NOT NULL)")
      end
    end

    it "is nullable with no default, so 'never recorded' stays distinguishable" do
      column = AuditLog::Change.columns_hash["dimensions"]

      expect(column.null).to be true
      expect(column.default).to be_nil
    end

    # A partition created AFTER the parent index exists inherits it, which is why
    # nothing in the partition lifecycle has to learn this feature exists.
    it "is inherited by a partition created later" do
      indexed = conn.select_values(<<~SQL)
        SELECT c.relname FROM pg_class c
         JOIN pg_inherits i ON i.inhrelid = c.oid
         JOIN pg_class p ON p.oid = i.inhparent
        WHERE p.relname = 'audit_changes_dimensions_idx'
      SQL

      partitions = AuditLog::Partitions.list.grep(/\Aaudit_changes_/)
      expect(indexed.size).to eq(partitions.size)
    end
  end
end
