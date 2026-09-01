# frozen_string_literal: true

require "rails_helper"

# Display-time association labels.
#
# The property every example here defends is the same one the rest of the suite
# defends from other angles: NOTHING GOES MISSING WITHOUT SAYING SO. A label is
# decoration layered on top of an id, so the failure modes worth testing are the
# ones where the decoration eats the fact, invents a fact, or hides its own
# failure -- not whether the string is pretty.
RSpec.describe "association labels" do
  def change_double(record_type:, diff:, record_id: 1)
    instance_double(AuditLog::Change, record_type: record_type, record_id: record_id, diff: diff)
  end

  describe AuditLog::RecordLabel do
    it "prefers to_audit_label over to_label, so a model can say something different to auditors" do
      record = Class.new do
        def to_audit_label = "for the auditor"
        def to_label       = "for everyone else"
      end.new

      expect(described_class.for(record)).to eq("for the auditor")
    end

    it "falls back to to_label, the convention the actor labels already use" do
      record = Class.new { def to_label = "Jane Doe <jane@example.com>" }.new

      expect(described_class.for(record)).to eq("Jane Doe <jane@example.com>")
    end

    it "uses to_s only when the model deliberately overrode it" do
      overridden = Class.new { def to_s = "SKU-1 — Widget" }.new
      inherited  = Class.new.new

      expect(described_class.for(overridden)).to eq("SKU-1 — Widget")
      expect(described_class.for(inherited)).to be_nil
    end

    # The decision recorded in CLAUDE.md: to_audit_label is the seam, so nothing
    # here guesses that a column named `name` is a label. A confidently wrong
    # caption on an audit screen is worse than no caption.
    it "never sniffs a name or title attribute" do
      record = Class.new do
        def name  = "Sniffable"
        def title = "Also sniffable"
      end.new

      expect(described_class.for(record)).to be_nil
      expect(described_class.labelable?(record.class)).to be(false)
    end

    # The difference from ActorLabel, and the reason the feature is opt-in: the
    # chain ends in nil, not in "Product #51". The id is already on the screen.
    it "ends the chain in nil rather than a Type #id fallback" do
      expect(described_class.for(Class.new.new)).to be_nil
    end

    # Shipment is the canary throughout: no to_audit_label, no to_label, no
    # overridden to_s, and no name or title column either -- so it is the model
    # that proves an un-opted-in type costs nothing and claims nothing.
    it "distinguishes 'I do not label this type' (nil) from 'none of those ids exist' ({})" do
      expect(described_class.batch("Shipment", [1, 2, 3])).to be_nil
      expect(described_class.batch("Product", [-1])).to eq({})
    end

    # The whole point of answering labelable? from the class alone.
    it "issues no query at all for a type that cannot produce a label" do
      expect(count_queries { described_class.batch("Shipment", [1, 2, 3]) }).to eq(0)
    end
  end

  describe AuditLog::LabelResolver do
    let(:product)  { create_product }
    let(:customer) { create_customer(name: "Northwind Supply") }
    let(:staff)    { create_user(name: "Raj Patel", role: "staff") }

    let(:order) do
      as_actor(staff) do
        Order.create!(customer: customer, created_by: staff,
                      line_items_attributes: [{ product_id: product.id, quantity: 2 }])
      end
    end

    # The trap that rules out convention-based discovery: `created_by_id`
    # de-suffixed and classified is "CreatedBy", which does not exist. Reflection
    # reads class_name: "User" off the belongs_to and gets it right.
    it "resolves a foreign key whose name does not match its target class" do
      change = changes_for(order).first
      resolver = described_class.new

      label = resolver.for_value(change, "created_by_id", staff.id, side: :new)

      expect(label).to eq(staff.to_label)
    end

    it "resolves through reflection for the ordinary cases" do
      change   = changes_for(order).first
      resolver = described_class.new

      expect(resolver.for_value(change, "customer_id", customer.id, side: :new)).to eq("Northwind Supply")
    end

    it "leaves a column that is not an association alone" do
      change   = changes_for(order).first
      resolver = described_class.new

      expect(resolver.for_value(change, "total_cents", 9347, side: :new)).to be_nil
    end

    # The Record cell beside it already names the record.
    it "never labels the record's own id column" do
      change   = changes_for(order).first
      resolver = described_class.new

      expect(resolver.for_value(change, "id", order.id, side: :new)).to be_nil
    end

    it "lets config.association_targets override reflection, and suppress it" do
      change = changes_for(order).first

      allow(AuditLog.config).to receive(:association_targets)
        .and_return({ "Order" => { "customer_id" => false } })

      expect(described_class.new.for_value(change, "customer_id", customer.id, side: :new)).to be_nil
    end

    it "reports a dangling foreign key as MISSING rather than as unlabelled" do
      change = change_double(record_type: "LineItem", diff: { "product_id" => [nil, 999_999_999] })

      label = described_class.new.for_value(change, "product_id", 999_999_999, side: :new)

      expect(label).to eq(described_class::MISSING)
    end

    # An un-opted-in model must not read as a page full of deletions.
    it "does not report ids of an unlabelled type as MISSING" do
      resolver = described_class.new

      expect(resolver.for("Shipment", 12_345)).to be_nil
    end

    it "batches: one query per type no matter how many rows reference it" do
      as_actor(staff) { 12.times { order.line_items.create!(product: product, quantity: 1) } }
      changes = AuditLog::Change.for_type("LineItem").order(:id).to_a
      expect(changes.size).to be >= 12

      resolver = described_class.new
      queries  = count_queries { resolver.warm(changes) }

      # LineItem (to_audit_label), Order and Product (overridden to_s) -- one
      # lookup each, for twelve-plus rows. Add a Shipment change to this page and
      # the count stays at three: an unlabelled type is pruned with no query.
      expect(queries).to eq(3)
    end

    # The comment above is a claim; this is the assertion behind it.
    it "issues no query for an unlabelled type even when its rows are on the page" do
      as_actor(staff) { order.shipments.create!(carrier: "UPS", tracking_number: "1Z999") }
      changes = AuditLog::Change.for_type("Shipment").order(:id).to_a
      expect(changes).not_to be_empty

      resolver = described_class.new
      queries  = count_queries { resolver.warm(changes) }

      # Order, for the shipment's order_id. Nothing for Shipment itself.
      expect(queries).to eq(1)
      expect(resolver.for("Shipment", changes.first.record_id)).to be_nil
    end

    it "resolves a miss on demand, so a screen that forgets to warm is slow and not wrong" do
      change   = changes_for(order).first
      resolver = described_class.new

      expect(resolver.for_value(change, "customer_id", customer.id, side: :new)).to eq("Northwind Supply")
    end

    it "is disabled entirely when the resolver is nil" do
      allow(AuditLog.config).to receive(:record_label_resolver).and_return(nil)
      change   = changes_for(order).first
      resolver = described_class.new

      expect(resolver).not_to be_enabled
      expect(resolver.for_value(change, "customer_id", customer.id, side: :new)).to be_nil
      expect(count_queries { resolver.warm([change]) }).to eq(0)
    end

    context "when the resolver raises" do
      let(:resolver) do
        allow(AuditLog.config).to receive(:record_label_resolver)
          .and_return(->(_type, _ids) { raise "label backend is down" })
        described_class.new
      end

      it "reports FAILED instead of taking the screen down" do
        change = changes_for(order).first

        expect { @label = resolver.for_value(change, "customer_id", customer.id, side: :new) }
          .not_to raise_error
        expect(@label).to eq(described_class::FAILED)
      end

      # The distinction the render depends on: "the screen could not answer" is
      # not "there was never a question".
      it "keeps FAILED distinguishable from an absent label" do
        change = changes_for(order).first

        expect(resolver.for_value(change, "customer_id", customer.id, side: :new))
          .not_to be_nil
      end
    end
  end

  describe "rendering", type: :request do
    let(:auditor)  { create_user(name: "Mei Chen", email: "mei@example.com", role: "auditor") }
    let(:staff)    { create_user(name: "Raj Patel", role: "staff") }
    let(:product)  { create_product }
    let(:customer) { create_customer(name: "Northwind Supply") }

    let!(:order) do
      as_actor(staff) do
        Order.create!(customer: customer, created_by: staff,
                      line_items_attributes: [{ product_id: product.id, quantity: 2 }])
      end
    end

    before { sign_in auditor }

    def body_for_order_history
      get audit.record_history_path(record_type: "Order", record_id: order.id)
      expect(response).to have_http_status(:ok)
      response.body
    end

    it "shows the label next to the id, never instead of it" do
      body = body_for_order_history

      expect(body).to include("Northwind Supply")
      expect(body).to include("(id: #{customer.id})")
    end

    # The structural invariant behind the whole design: every label rendered is
    # accompanied by the id it annotates. If these ever diverge, a label has
    # replaced a stored fact somewhere.
    it "renders exactly as many ids as labels" do
      body = body_for_order_history

      expect(body.scan(/class="assoc-label"/).size)
        .to eq(body.scan(/class="assoc-id"/).size)
      expect(body.scan(/class="assoc-label"/).size).to be > 0
    end

    it "discloses that labels are resolved live" do
      expect(body_for_order_history).to include("ids are what the audit log recorded")
    end

    it "says nothing about labels on a screen where nothing was labelled" do
      allow(AuditLog.config).to receive(:record_label_resolver).and_return(nil)

      expect(body_for_order_history).not_to include("ids are what the audit log recorded")
    end

    # The opt-in guarantee: turning the feature off must return the screen to
    # exactly what it rendered before any of this existed.
    it "renders bare ids, and still renders, with labelling disabled" do
      labelled = body_for_order_history
      allow(AuditLog.config).to receive(:record_label_resolver).and_return(nil)
      bare = body_for_order_history

      expect(bare).not_to include("assoc-label")
      expect(bare).to include(">#{customer.id}<")
      expect(labelled).to include("Northwind Supply")
    end

    it "flags a dangling foreign key instead of showing an empty cell" do
      LineItem.where(order_id: order.id).delete_all
      Product.where(id: product.id).delete_all

      body = body_for_order_history_for_line_items

      expect(body).to include("(not found)")
      expect(body).to include(product.id.to_s)
    end

    def body_for_order_history_for_line_items
      get audit.record_path("LineItem")
      expect(response).to have_http_status(:ok)
      response.body
    end

    it "keeps the screen up when the resolver raises, and says the lookup failed" do
      allow(AuditLog.config).to receive(:record_label_resolver)
        .and_return(->(_type, _ids) { raise "label backend is down" })

      body = body_for_order_history

      expect(body).to include("(label unavailable)")
      expect(body).to include(">#{customer.id}<")
    end

    # Redaction removes values; a label lookup must not put one back, and must not
    # try to resolve the marker string as an id.
    it "does not label a redacted value" do
      AuditLog::Redaction.redact_record!(record_type: "Order", record_id: order.id,
                                         reason: "erasure request 41", columns: %w[customer_id])

      body = body_for_order_history

      expect(body).to include("redacted")
      expect(body).not_to include("Northwind Supply")
    end

    # CSV is the evidence artifact. The diff column ships the ids that were
    # recorded, with no display-layer decoration in it.
    it "leaves the CSV export as raw ids" do
      get audit.record_history_path(record_type: "Order", record_id: order.id, format: "csv")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("\"customer_id\"")
      expect(response.body).not_to include("Northwind Supply")
      expect(response.body).not_to include("assoc-label")
    end
  end
end
