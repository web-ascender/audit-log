# frozen_string_literal: true

require "rails_helper"

# The auditor UI end to end: does each screen actually render, and is it
# reachable only by someone allowed to see it.
RSpec.describe "the auditor UI", type: :request do
  let(:auditor) { create_user(name: "Mei Chen", email: "mei@example.com", role: "auditor") }
  let(:staff)   { create_user(name: "Raj Patel", email: "raj@example.com", role: "staff") }

  before do
    @order = as_actor(staff) do
      order = Order.create!(customer: create_customer, created_by: staff,
                            line_items_attributes: [{ product_id: create_product.id, quantity: 2 }])
      AuditLog.notify("order.created", order_id: order.id, reference: order.reference,
                                       customer_name: order.customer.name, line_count: 1)
      order
    end
    as_actor(staff) { @order.submit! }
  end

  context "as an auditor" do
    before { sign_in auditor }

    it "renders the overview" do
      get audit.root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Audit overview")
      expect(response.body).to include("row changes (layer 1)")
    end

    it "renders an actor's activity, with the drill-down to the records touched" do
      get audit.actor_path(staff.id, actor_type: "User")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Raj Patel")
      expect(response.body).to include("Submitted order")
      expect(response.body).to include("record changed in this action").or include("records changed")
    end

    # The fixed row caps this replaced were a silent truncation: an auditor saw
    # the newest 200 rows with nothing on the page saying there were more.
    it "pages a record's history by cursor instead of capping it" do
      as_actor(staff) { 4.times { |i| @order.update!(notes: "revision #{i}") } }

      get audit.record_history_path(record_type: "Order", record_id: @order.id), params: { page_limit: nil }
      expect(response).to have_http_status(:ok)

      first_page = response.body
      expect(first_page).to include("End of results.").or include("Older")
    end

    it "carries the cursor forward and never repeats a row" do
      as_actor(staff) { 8.times { |i| @order.update!(notes: "revision #{i}") } }
      allow(AuditLog.config).to receive(:page_size).and_return(3)

      get audit.record_history_path(record_type: "Order", record_id: @order.id)
      ids = response.body.scan(/data-change-id="(\d+)"/).flatten
      cursor = response.body[/[?&]page=([A-Za-z0-9_-]+)/, 1]
      expect(cursor).to be_present

      get audit.record_history_path(record_type: "Order", record_id: @order.id), params: { page: cursor }
      expect(response).to have_http_status(:ok)
      next_ids = response.body.scan(/data-change-id="(\d+)"/).flatten
      expect(ids & next_ids).to be_empty unless ids.empty?
    end

    # A cursor minted on another screen must not silently drop rows.
    it "recovers from a foreign cursor by returning to the newest page" do
      get audit.record_history_path(record_type: "Order", record_id: @order.id),
          params: { page: "bm90LWEtcmVhbC1jdXJzb3I" }
      expect(response).to have_http_status(:ok)
    end

    it "renders the complete record-layer view for an actor" do
      get audit.actor_path(staff.id, actor_type: "User", view: "changes")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("LineItem")
    end

    it "renders one record's full history" do
      get audit.record_history_path(record_type: "Order", record_id: @order.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Order ##{@order.id}")
    end

    # The change rows are the compliance-grade answer, so they stay the landing
    # tab. A ?view= a hostile URL invented must not silently select something
    # else -- it falls back to the complete layer, never to the capped one.
    it "defaults a record's history to the change rows" do
      get audit.record_history_path(record_type: "Order", record_id: @order.id, view: "nonsense")
      expect(response.body).to include("straight from the database triggers")
    end

    it "renders the narrative tab for one record, from the subject index" do
      get audit.record_history_path(record_type: "Order", record_id: @order.id, view: "actions")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Submitted order")
      expect(response.body).to include("Also touched this record")
    end

    # price.bulk_adjusted is registered with no subject: lambda and writes with
    # update_all. A record timeline built on the subject index alone loses it
    # entirely -- which is the whole reason the second section exists.
    it "surfaces an action that touched a record without naming it as subject" do
      product = create_product(price_cents: 1_000)
      as_actor(staff) do
        count = Product.where(id: product.id).update_all(price_cents: 1_100)
        AuditLog.notify("price.bulk_adjusted", percent: 10, count: count)
      end

      get audit.record_history_path(record_type: "Product", record_id: product.id, view: "actions")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("price.bulk_adjusted")
    end

    # A capped list that does not say it is capped is the failure mode this
    # library is built to avoid. The cap is also escapable.
    it "discloses the correlated section's scan budget when it runs out" do
      product = create_product(price_cents: 1_000)
      as_actor(staff) { 3.times { |i| product.update!(price_cents: 2_000 + i) } }

      get audit.record_history_path(record_type: "Product", record_id: product.id,
                                    view: "actions", scan: 2)
      expect(response.body).to include("2</strong> most recent")
      expect(response.body).to include("more history than that")
      expect(response.body).to include("scan=8")
    end

    it "exports whichever tab of a record's history is open" do
      get audit.record_history_path(record_type: "Order", record_id: @order.id,
                                    view: "actions", format: :csv)
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("Order-#{@order.id}-actions")
      expect(response.body).to include("order.submitted")
    end

    # The bug this guards: the action links were the id's first 8 characters,
    # which in a UUIDv7 are timestamp bits with ~65 seconds of resolution. Two
    # actions on one record seconds apart -- the ordinary case on a history
    # screen -- rendered as the same string.
    it "gives each action on a record a distinguishable link" do
      get audit.record_history_path(record_type: "Order", record_id: @order.id)

      ids = AuditLog::Change.where(record_type: "Order", record_id: @order.id)
                            .distinct.pluck(:request_id).compact
      expect(ids.size).to be > 1
      expect(ids.map { |i| i.first(8) }.uniq.size).to eq(1)   # the old rendering collided

      shown = ids.map { |i| i.split("-").last }
      expect(shown.uniq.size).to eq(ids.size)
      shown.each { |s| expect(response.body).to include(s) }
    end

    it "renders a record class with a field filter" do
      get audit.record_path("Order", columns: ["status"])
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Order changes")
    end

    it "renders the action report" do
      get audit.action_path("order.submitted")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("order.submitted")
      expect(response.body).to include("Raj Patel")
    end

    it "renders one action with everything it touched" do
      event = AuditLog::Event.find_by!(action: "order.created")
      get audit.request_path(event.request_id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Order")
      expect(response.body).to include("LineItem")
    end

    it "renders the out-of-band screen" do
      AuditLog::Current.reset
      create_product

      get audit.out_of_band_index_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Out-of-band changes")
    end

    it "renders the action index" do
      get audit.actions_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("order.submitted")
    end

    # audit_events.metadata is the action's own payload -- the structured values
    # behind the summary sentence. It was stored on every event and exported by
    # CsvExport from the start, and rendered on no screen at all; DESIGN §11.3
    # assumes the opposite. These pin the three states apart.
    describe "the event payload" do
      it "renders the payload fields on the request drill-down" do
        event = AuditLog::Event.for_action("order.submitted").newest_first.first

        get audit.request_path(event.request_id)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("payload fields")
        expect(response.body).to include("total_cents")
        expect(response.body).to include(event.metadata["reference"])
      end

      it "shows nothing for an action that carried no payload" do
        as_actor(staff) { AuditLog.notify("order.approved") }
        event = AuditLog::Event.for_action("order.approved").newest_first.first
        expect(event.metadata).to eq({})

        get audit.request_path(event.request_id)
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("payload field")
        expect(response.body).not_to include("Payload redacted")
      end

      # The case the whole partial exists for. A redacted payload and an absent
      # one are the same empty jsonb; rendering them identically turns an erasure
      # into a silent hole, which is the one thing §13 is built to prevent. And
      # the disclosure must not be behind a <details> -- a notice you have to
      # click for has not been given.
      it "says so when the payload was redacted, without collapsing it" do
        customer = @order.customer
        as_actor(staff) do
          AuditLog.notify("customer.updated", customer_id: customer.id,
                                              name: customer.name, fields: %w[email])
        end
        AuditLog::Redaction.redact_record!(record_type: "Customer", record_id: customer.id,
                                           reason: "DSR-1182")

        event = AuditLog::Event.for_action("customer.updated").newest_first.first
        expect(event.metadata).to eq({})

        get audit.request_path(event.request_id)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Payload redacted")
        expect(response.body).not_to include("payload field")
        expect(response.body).to match(%r{<p class="redaction-note">})
      end
    end

    # A NULL actor is stored as NULL, never as the string "System" -- so every
    # screen has to render that at display time, and the "who triggered it"
    # rollup is the one place that gets a TUPLE rather than a record and so
    # cannot call actor_display. It re-spelled the fallback chain, dropped the
    # nil branch, and took the whole screen down with UrlGenerationError the
    # first time an actorless action reached it: `audit.redaction`, whose rake
    # task passes no actor.
    it "renders an action whose events have no actor" do
      AuditLog::Redaction.redact_record!(record_type: "Customer", record_id: @order.customer_id,
                                         reason: "DSR-1182")
      event = AuditLog::Event.for_action("audit.redaction").newest_first.first
      expect(event.actor_id).to be_nil
      expect(event.actor_type).to be_nil

      get audit.action_path("audit.redaction")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("System")
    end

    # The rollup must not link a NULL actor anywhere: there is no activity page
    # for one, because it is not a someone.
    it "does not link the System row to an actor page" do
      AuditLog::Redaction.redact_record!(record_type: "Customer", record_id: @order.customer_id,
                                         reason: "DSR-1182")

      get audit.action_path("audit.redaction")
      expect(response.body).not_to match(%r{href="[^"]*/audit/actors/\?[^"]*"})
      expect(response.body).to match(%r{<span class="muted"[^>]*>System</span>})
    end

    it "renders the actor picker" do
      get audit.actors_path(q: "Raj")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Raj Patel")
    end
  end

  context "as a non-auditor" do
    before { sign_in staff }

    it "refuses access to the audit screens" do
      # The authorize hook raises ActionController::RoutingError, which Rails
      # renders as a 404 rather than a 403 -- deliberately: the existence of an
      # audit console is not something to advertise to someone who cannot use it.
      get audit.root_path
      expect(response).to have_http_status(:not_found)
    end
  end

  context "signed out" do
    # What the HOST app does to an unauthenticated request, not what the library
    # does -- and deliberately different from the reference app, which redirects
    # because Devise does. This app answers 401 from a hand-rolled
    # authenticate_user!. Both are fine; the library never sees the difference.
    # What matters is that the audit screens are not reachable without an actor.
    it "does not serve the audit screens without an actor" do
      get audit.root_path

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include("Audit overview")
    end
  end
end
