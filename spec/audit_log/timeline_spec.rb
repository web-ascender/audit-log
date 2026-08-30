# frozen_string_literal: true

require "rails_helper"

# The host-app-facing contract: a paginated list of UNITS OF WORK for one record.
#
# What these examples defend is not "the query returns rows" -- it is that the
# value objects keep the rules the auditor UI encodes, because a host app that
# renders these objects gets those rules whether it knows them or not. Every one
# of them is a rule somebody would otherwise re-derive, and get wrong on a screen
# that looks fine.
RSpec.describe AuditLog::Timeline do
  let(:staff) { create_user(name: "Raj Patel", role: "staff") }

  # Pages the way a real screen does -- through AuditLog::Pagination rather than
  # a bare Page.new -- so the index is exercised against FULL_PRECISION and the
  # cursor-mismatch fallback, not just against the happy path.
  class TimelinePager
    include AuditLog::Pagination
    attr_reader :params

    def initialize(cursor = nil)
      @params = { page: cursor }
    end
  end

  def timeline(record) = described_class.for(record)

  def page_of(record, limit: 50, **kwargs)
    tl = described_class.for(record, **kwargs)
    tl.activities(tl.activity_keys.limit(limit).to_a)
  end

  describe "the grain" do
    # The whole reason a correlation id exists. A save that writes an order and
    # its line items is ONE thing that happened, not N rows to reassemble.
    it "renders one activity per unit of work, not one per audit row" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: 3.times.map { { product_id: create_product.id, quantity: 1 } })
      end

      activities = page_of(order)
      expect(activities.size).to eq(1)
      expect(activities.first.also_touched.map(&:type)).to include("LineItem")
    end

    it "counts a touched record once even when the action wrote it twice" do
      order = as_actor(staff) do
        o = Order.create!(customer: create_customer, created_by: staff,
                          line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
        o.line_items.first.update!(quantity: 9)
        o
      end

      touched = page_of(order).first.also_touched
      expect(touched.map { |t| [t.type, t.id] }.uniq.size).to eq(touched.size)
    end

    it "does not list the record itself among the records it also touched" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end

      expect(page_of(order).first.also_touched.map(&:type)).not_to include("Order")
    end
  end

  # The changes-only index paged over change ROWS and grouped them, so one unit
  # of work could straddle a cursor and needed a de-duplication pass. Keying on
  # the unit itself deletes that problem instead of managing it -- but the
  # PROPERTY it protected still has to hold, so it is pinned here directly.
  describe "paging the activity keys" do
    let!(:order) do
      as_actor(staff) do
        o = Order.create!(customer: create_customer, created_by: staff,
                          line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
        o.update!(notes: "first")
        o.update!(notes: "second")   # three writes to the order, ONE request
        o
      end
    end

    it "collapses several writes in one request into a single unit of work" do
      tl = described_class.for(order)
      expect(AuditLog::Change.for_record("Order", order.id).count).to be > 1
      expect(tl.activity_keys.to_a.size).to eq(1)

      activity = tl.activities(tl.activity_keys.to_a).first
      expect(activity.changes.size).to be > 1
      expect(activity.changed_columns).to include("notes")
    end

    it "pages without dropping or repeating a unit of work" do
      as_actor(staff) { order.update!(notes: "another action") }
      as_actor(staff) { order.submit! }
      Order.where(id: order.id).update_all(notes: "out of band one")
      Order.where(id: order.id).update_all(notes: "out of band two")

      tl    = described_class.for(order)
      all   = tl.activity_keys.to_a.map(&:key)
      seen  = []
      cursor = nil

      10.times do
        pagy = TimelinePager.new(cursor).paginate(tl.activity_keys, limit: 2)
        break if pagy.records.empty?

        seen.concat(pagy.records.map(&:key))
        cursor = pagy.next
        break if cursor.nil?
      end

      expect(all.size).to be >= 4
      expect(seen.size).to eq(seen.uniq.size)      # nothing repeated
      expect(seen.sort).to eq(all.sort)            # nothing dropped
    end

    # Each uncorrelated write is its own unit of work. Grouping on a bare
    # request_id would collapse every NULL in the log into ONE row.
    it "keeps each out-of-band write as its own unit" do
      Order.where(id: order.id).update_all(notes: "oob a")
      Order.where(id: order.id).update_all(notes: "oob b")

      oob = described_class.for(order).activity_keys.to_a.select(&:out_of_band?)
      expect(oob.size).to eq(2)
      expect(oob.map(&:key).uniq.size).to eq(2)
      expect(oob.map(&:change_id).compact.size).to eq(2)
    end
  end

  # THE SECOND LEG. Every one of these is an action that named this record and
  # wrote no change row TO it, so a changes-only index drops all four.
  describe "events that wrote no change row to this record" do
    it "includes an action that wrote only children" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end
      before_count = page_of(order).size

      # A line item is added and narrated; the order row itself never changes.
      as_actor(staff) do
        LineItem.create!(order: order, product: create_product, quantity: 2)
        AuditLog.notify("order.updated", order_id: order.id,
                                         reference: order.reference, line_count: 2)
      end

      activities = page_of(order)
      expect(activities.size).to eq(before_count + 1)
      added = activities.find { |e| e.action == "order.updated" }
      expect(added).not_to be_nil
      expect(added.changes).to be_empty              # nothing was written to the order
      expect(added.also_touched.map(&:type)).to include("LineItem")
    end

    it "includes an action that wrote nothing at all" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end
      as_actor(staff) do
        AuditLog.notify("order.shipped", order_id: order.id, reference: order.reference,
                                         carrier: "UPS", tracking_number: "T1")
      end

      shipped = page_of(order).find { |e| e.action == "order.shipped" }
      expect(shipped).not_to be_nil
      expect(shipped.changes).to be_empty
      expect(shipped.field_changes).to be_empty
      expect(shipped.operations).to be_empty
      expect(shipped.headline).to include("Shipped order")
      expect(shipped.occurred_at).not_to be_nil     # from the unit, not from changes
    end

    # A record whose table is in config.unaudited_tables has NO trigger, so it
    # has no change rows ever and a changes-only index renders an empty page --
    # even when events name it as their subject. Simulated with a type that has
    # no audited table at all.
    it "builds a timeline for a record that has no change rows whatsoever" do
      as_actor(staff) do
        AuditLog.notify("customer.created", customer_id: 987_654, name: "Unaudited Co")
      end

      tl = described_class.new(record_type: "Customer", record_id: 987_654)
      expect(AuditLog::Change.for_record("Customer", 987_654).count).to eq(0)

      activities = tl.activities(tl.activity_keys.to_a)
      expect(activities.size).to eq(1)
      expect(activities.first.headline).to include("Unaudited Co")
      expect(activities.first.kind).to eq(:narrative)
    end
  end

  describe "the narrative" do
    it "carries the summary a registered action stored" do
      order = as_actor(staff) do
        o = Order.create!(customer: create_customer, created_by: staff,
                          line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
        AuditLog.notify("order.created", order_id: o.id, reference: o.reference,
                                         customer_name: o.customer.name, line_count: 1)
        o
      end

      activity = page_of(order).first
      expect(activity.kind).to eq(:narrative)
      expect(activity.headline).to include("Drafted order")
      expect(activity.action).to eq("order.created")
      expect(activity.source).to eq("web")
    end

    # The library does NOT invent a sentence from column names. A generated
    # phrasing is this gem's wording, not the app author's; it would re-render
    # differently after a gem upgrade, and on the page it would be
    # indistinguishable from a summary frozen at emit time. Same discipline as
    # RecordLabel's chain ending in nil -- nil IS the contract.
    it "returns a nil headline rather than inventing one, when nothing registered" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end

      activity = page_of(order).first
      expect(activity.kind).to eq(:change_only)
      expect(activity.headline).to be_nil
      expect(activity.source).to be_nil          # audit_changes does not record one
      # ...but the raw materials the host composes from are all present.
      expect(activity.operations).to include(AuditLog::Change::INSERT)
      expect(activity.record_type).to eq("Order")
      expect(activity.changed_columns).to include("status")
    end

    # One unit of work can emit actions about several records. This record's
    # activity must lead with the action about THIS record.
    it "prefers the event that named this record as its subject" do
      order = as_actor(staff) do
        o = Order.create!(customer: create_customer, created_by: staff,
                          line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
        AuditLog.notify("customer.created", customer_id: o.customer_id, name: o.customer.name)
        AuditLog.notify("order.created", order_id: o.id, reference: o.reference,
                                         customer_name: o.customer.name, line_count: 1)
        o
      end

      expect(page_of(order).first.action).to eq("order.created")
    end
  end

  describe "AuditLog::Timeline::FieldChange" do
    # Three shapes, three meanings. A view that renders the second and third
    # identically reports a field being EMPTIED as a field being filled in.
    it "distinguishes set-on-insert from cleared from changed" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff, notes: "hello",
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end
      as_actor(staff) { order.update!(notes: nil) }

      all = page_of(order).flat_map(&:field_changes)

      set     = all.find { |fc| fc.column == "notes" && fc.to == "hello" }
      cleared = all.find { |fc| fc.column == "notes" && fc.from == "hello" }

      expect(set.set?).to be(true)
      expect(set.cleared?).to be(false)
      expect(cleared.cleared?).to be(true)
      expect(cleared.set?).to be(false)
    end

    it "labels an association id without dropping it" do
      product = create_product
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: product.id, quantity: 1 }])
      end

      tl         = described_class.new(record_type: "LineItem", record_id: order.line_items.first.id)
      activity      = tl.activities(tl.activity_keys.to_a).first
      product_fc = activity.field_changes.find { |fc| fc.column == "product_id" }

      expect(product_fc.to).to eq(product.id)          # the recorded id survives
      expect(product_fc.association?).to be(true)
    end
  end

  describe "AuditLog::Timeline::TouchedRecord" do
    # DESIGN 11.8: the label is resolved live from current state, the id is what
    # the log recorded. A host building a pretty view will want to drop the id,
    # so the pretty method is the one that keeps it.
    it "always carries the recorded id, labelled or not" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end

      touched = page_of(order).first.also_touched.first
      expect(touched.to_s).to include("##{touched.id}")
      expect(touched.identifier).to eq("#{touched.type} ##{touched.id}")
    end

    it "links through config.record_url, and to nothing when the host set none" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end
      touched = page_of(order).first.also_touched.first

      expect(AuditLog.config.record_url).to be_nil
      expect(touched.url).to be_nil                     # never guessed from the class name

      begin
        AuditLog.config.record_url = ->(type, id) { "/#{type.underscore}s/#{id}" }
        line_item = page_of(order).first.also_touched.find { |t| t.type == "LineItem" }
        expect(line_item.url).to match(%r{/line_items/\d+})
      ensure
        AuditLog.config.record_url = nil
      end
    end
  end

  describe "AuditLog::Timeline::Actor" do
    # A nil actor stores NULL, never the string "System". Storing it would make a
    # console session indistinguishable from a genuine scheduled action, so the
    # fallback lives at display time and in one place.
    it "renders a missing actor as System without claiming it is linkable" do
      product = create_product
      Product.where(id: product.id).update_all(price_cents: 5_000)   # no actor, no request

      actor = page_of(product).first.actor
      expect(actor).to be_system
      expect(actor.display).to eq("System")
      expect(actor.linkable?).to be(false)
      expect(actor.url).to be_nil
    end

    it "carries the label the row snapshotted, not a live lookup" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end
      staff.update!(name: "Renamed Afterwards")

      expect(page_of(order).first.actor.display).to include("Raj Patel")
    end
  end

  describe "out-of-band writes" do
    it "gives each uncorrelated write its own activity and says so" do
      product = create_product
      Product.where(id: product.id).update_all(price_cents: 4_000)

      activity = page_of(product).first
      expect(activity).to be_out_of_band
      expect(activity.request_id).to be_nil
      expect(activity.also_touched).to be_empty
    end
  end

  describe "redaction" do
    # An emptied payload and an action that carried none are the same empty
    # jsonb. Redaction leaves no flag column by design, so the marker string is
    # the only trace -- and an activity that cannot tell them apart renders an
    # erasure as an absence.
    it "reports a redacted activity as redacted rather than as empty" do
      customer = create_customer(name: "Erasure Target")
      as_actor(staff) { customer.update!(name: "Changed Once") }
      AuditLog::Redaction.redact_record!(record_type: "Customer", record_id: customer.id,
                                         reason: "DSR-9001")

      expect(page_of(customer).any?(&:redacted?)).to be(true)
    end
  end

  describe "#as_json" do
    it "serializes an activity whole, for a host that renders it elsewhere" do
      order = as_actor(staff) do
        o = Order.create!(customer: create_customer, created_by: staff,
                          line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
        AuditLog.notify("order.created", order_id: o.id, reference: o.reference,
                                         customer_name: o.customer.name, line_count: 1)
        o
      end

      json = page_of(order).first.as_json
      expect(JSON.parse(JSON.generate(json))).to include(
        "kind" => "narrative", "record_type" => "Order", "out_of_band" => false
      )
      expect(json["actor"]).to include("display")
      expect(json["field_changes"]).to be_an(Array)
      expect(json["also_touched"].first).to include("identifier")
      # Microseconds, for the same reason the keyset cursor needs them: a
      # millisecond-truncated timestamp names an instant just before its own row.
      expect(json["occurred_at"]).to match(/\.\d{6}/)
    end
  end

  describe "the date bound" do
    let!(:order) do
      as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end
    end

    it "is unbounded by default, and says so" do
      tl = described_class.for(order)
      expect(tl).not_to be_bounded
      expect(tl.scope_description).to eq("across all retained history")
      expect(tl.window).to be_nil
    end

    it "narrows both legs, and a narrowed timeline never looks complete" do
      tl = described_class.for(order, range: 30.days.ago..Time.current)
      expect(tl).to be_bounded
      expect(tl.scope_description).to match(/\Afrom \d{4}-\d{2}-\d{2} to \d{4}-\d{2}-\d{2}\z/)

      sql = tl.activity_keys.to_sql
      # INSIDE each leg. On the outer aggregate the planner cannot push a
      # predicate on max(occurred_at) back through the GROUP BY, so it would
      # prune nothing.
      expect(sql.scan(/occurred_at >= /).size).to eq(2)
      expect(sql.scan(/occurred_at <= /).size).to eq(2)
    end

    # An endless range is closed at the current instant, which loses nothing:
    # occurred_at is filled by clock_timestamp() and no row can be future-dated
    # (utc_storage_spec). It is worth 3x in partitions touched.
    it "closes an endless range at the current instant" do
      tl = described_class.for(order, range: 30.days.ago..)
      expect(tl.window.last).not_to be_nil
      expect(tl.activity_keys.to_sql.scan(/occurred_at <= /).size).to eq(2)
    end

    # Assert PRUNING from the plan, never that a specific index was chosen: on a
    # small test database the planner correctly picks a seq scan regardless.
    it "prunes partitions the bound excludes" do
      conn = AuditLog::Change.connection
      count = lambda do |tl|
        plan = conn.select_values("EXPLAIN #{tl.activity_keys.to_sql}").join("\n")
        plan.scan(/on (audit_(?:changes|events)_\d{4}_\d{2})/).flatten.uniq.size
      end

      unbounded = count.call(described_class.for(order))
      bounded   = count.call(described_class.for(order, range: 1.hour.ago..Time.current))

      expect(unbounded).to be > 0
      expect(bounded).to be < unbounded
    end

    it "excludes rows outside the window from the activities themselves" do
      inside  = described_class.for(order, range: 1.hour.ago..Time.current)
      outside = described_class.for(order, range: 10.years.ago..9.years.ago)

      expect(inside.activities(inside.activity_keys.to_a)).not_to be_empty
      expect(outside.activities(outside.activity_keys.to_a)).to be_empty
    end

    describe "#older_than_window?" do
      # OPT-IN and never called from #activities: it looks below range.begin, which
      # is the one thing the bound exists to avoid. Calling it per page would
      # hand back the pruning the caller just bought.
      it "reports history before the window, so 'end of results' can be honest" do
        recent = described_class.for(order, range: 1.hour.ago..Time.current)
        expect(recent.older_than_window?).to be(false)

        future = described_class.for(order, range: 1.day.from_now..2.days.from_now)
        expect(future.older_than_window?).to be(true)
      end

      it "is false on an unbounded timeline, which has no window to be older than" do
        expect(described_class.for(order).older_than_window?).to be(false)
      end
    end
  end

  describe "the activity keys" do
    it "returns an ordered, unlimited relation so the caller paginates it" do
      tl = described_class.new(record_type: "Order", record_id: 1)
      expect(tl.activity_keys.limit_value).to be_nil
      expect(tl.activity_keys.to_sql).to match(/ORDER BY.*occurred_at.*DESC/i)
    end

    it "takes the host's own record without keeping a reference to it" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
      end

      tl = described_class.for(order)
      expect(tl.record_type).to eq("Order")
      expect(tl.record_id).to eq(order.id)
    end

    it "returns no activities for an empty page without querying" do
      expect(described_class.new(record_type: "Order", record_id: 1).activities([])).to eq([])
    end
  end
end
