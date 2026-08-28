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

  def timeline(record) = described_class.for(record)

  def page_of(record, limit: 50)
    tl = timeline(record)
    tl.entries(tl.changes.limit(limit).to_a)
  end

  describe "the grain" do
    # The whole reason a correlation id exists. A save that writes an order and
    # its line items is ONE thing that happened, not N rows to reassemble.
    it "renders one entry per unit of work, not one per audit row" do
      order = as_actor(staff) do
        Order.create!(customer: create_customer, created_by: staff,
                      line_items_attributes: 3.times.map { { product_id: create_product.id, quantity: 1 } })
      end

      entries = page_of(order)
      expect(entries.size).to eq(1)
      expect(entries.first.also_touched.map(&:type)).to include("LineItem")
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

  # THE PAGE-BOUNDARY RULE. An entry is hydrated with every change row of its
  # unit of work, including rows past the end of the page -- that is what keeps a
  # unit of work whole at a cursor. The cost is that the next page starts at one
  # of those older rows and would render the entry again.
  describe "the page boundary" do
    let!(:order) do
      as_actor(staff) do
        o = Order.create!(customer: create_customer, created_by: staff,
                          line_items_attributes: [{ product_id: create_product.id, quantity: 1 }])
        o.update!(notes: "first")
        o.update!(notes: "second")   # three writes to the order, ONE request
        o
      end
    end

    it "keeps a unit of work whole when the page cuts through it" do
      tl    = described_class.new(record_type: "Order", record_id: order.id)
      entry = tl.entries(tl.changes.limit(1).to_a).first

      # The page held one row; the entry holds every row of that unit of work.
      expect(entry.changes.size).to be > 1
      expect(entry.changed_columns).to include("notes")
    end

    it "does not render the same unit of work twice across pages" do
      tl   = described_class.new(record_type: "Order", record_id: order.id)
      rows = tl.changes.to_a

      first  = tl.entries(rows.first(1))
      second = tl.entries(rows.drop(1))

      expect(first.map(&:request_id)).to eq([rows.first.request_id])
      # Every row on page 2 belongs to a unit of work already shown in full.
      expect(second).to be_empty
    end

    it "still renders an entry whose rows all fall inside one page" do
      as_actor(staff) { order.update!(notes: "a separate action") }

      tl      = described_class.new(record_type: "Order", record_id: order.id)
      entries = tl.entries(tl.changes.to_a)
      expect(entries.map(&:request_id).uniq.size).to eq(2)
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

      entry = page_of(order).first
      expect(entry.kind).to eq(:narrative)
      expect(entry.headline).to include("Drafted order")
      expect(entry.action).to eq("order.created")
      expect(entry.source).to eq("web")
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

      entry = page_of(order).first
      expect(entry.kind).to eq(:change_only)
      expect(entry.headline).to be_nil
      expect(entry.source).to be_nil          # audit_changes does not record one
      # ...but the raw materials the host composes from are all present.
      expect(entry.operations).to include(AuditLog::Change::INSERT)
      expect(entry.record_type).to eq("Order")
      expect(entry.changed_columns).to include("status")
    end

    # One unit of work can emit actions about several records. This record's
    # entry must lead with the action about THIS record.
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
      entry      = tl.entries(tl.changes.to_a).first
      product_fc = entry.field_changes.find { |fc| fc.column == "product_id" }

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
    it "gives each uncorrelated write its own entry and says so" do
      product = create_product
      Product.where(id: product.id).update_all(price_cents: 4_000)

      entry = page_of(product).first
      expect(entry).to be_out_of_band
      expect(entry.request_id).to be_nil
      expect(entry.also_touched).to be_empty
    end
  end

  describe "redaction" do
    # An emptied payload and an action that carried none are the same empty
    # jsonb. Redaction leaves no flag column by design, so the marker string is
    # the only trace -- and an entry that cannot tell them apart renders an
    # erasure as an absence.
    it "reports a redacted entry as redacted rather than as empty" do
      customer = create_customer(name: "Erasure Target")
      as_actor(staff) { customer.update!(name: "Changed Once") }
      AuditLog::Redaction.redact_record!(record_type: "Customer", record_id: customer.id,
                                         reason: "DSR-9001")

      expect(page_of(customer).any?(&:redacted?)).to be(true)
    end
  end

  describe "#as_json" do
    it "serializes an entry whole, for a host that renders it elsewhere" do
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

  describe "the spine" do
    it "returns an ordered, unlimited relation so the caller paginates it" do
      tl = described_class.new(record_type: "Order", record_id: 1)
      expect(tl.changes.limit_value).to be_nil
      expect(tl.changes.to_sql).to match(/ORDER BY.*occurred_at.*DESC/i)
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

    it "returns no entries for an empty page without querying" do
      expect(described_class.new(record_type: "Order", record_id: 1).entries([])).to eq([])
    end
  end
end
