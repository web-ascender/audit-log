# frozen_string_literal: true

require "rails_helper"
require "csv"

# ROLLOUT Q6. The property that matters is the same one keyset pagination
# bought: an export of an audit log must be complete, or it is worse than none.
RSpec.describe "CSV export", type: :request do
  let(:auditor) { create_user(name: "Mei Chen", email: "mei@example.com", role: "auditor") }
  let(:staff)   { create_user(name: "Raj Patel", email: "raj@example.com", role: "staff") }

  before do
    @order = as_actor(staff) do
      Order.create!(customer: create_customer, created_by: staff,
                    line_items_attributes: [{ product_id: create_product.id, quantity: 2 }])
    end
    sign_in auditor
  end

  def csv_from(response)
    CSV.parse(response.body, headers: true)
  end

  it "serves a downloadable file with the audit columns" do
    get audit.record_history_path(record_type: "Order", record_id: @order.id, format: :csv)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    # The filename carries the TAB. One record's history exports two different
    # populations from one URL, and two evidence artifacts that differ in content
    # must not arrive under one name.
    expect(response.headers["Content-Disposition"]).to match(/attachment; filename="audit-Order-#{@order.id}-changes-\d{8}T\d{6}Z\.csv"/)
    expect(csv_from(response).headers).to include("occurred_at", "operation", "diff", "actor_label")
  end

  # The export exists because the screen pages. If it applied its own cap it
  # would put the silent truncation straight back.
  it "exports every row, past any one page" do
    as_actor(staff) { 12.times { |i| @order.update!(notes: "note #{i}") } }
    allow(AuditLog.config).to receive(:page_size).and_return(3)

    get audit.record_history_path(record_type: "Order", record_id: @order.id, format: :csv)
    rows = csv_from(response)

    expected = AuditLog::Change.for_type("Order").where(record_id: @order.id).count
    expect(expected).to be > 3
    expect(rows.size).to eq(expected)
  end

  # Batching walks the keyset in batches; a boundary must not drop or repeat.
  it "crosses its own batch boundary without dropping or repeating a row" do
    as_actor(staff) { 10.times { |i| @order.update!(notes: "note #{i}") } }
    stub_const("AuditLog::CsvExport::BATCH", 3)

    get audit.record_history_path(record_type: "Order", record_id: @order.id, format: :csv)
    ids = csv_from(response).map { |r| [r["occurred_at"], r["record_id"]] }

    expect(ids.uniq.size).to eq(ids.size)
    expect(ids.size).to eq(AuditLog::Change.for_type("Order").where(record_id: @order.id).count)
  end

  it "keeps the screen's ordering, newest first" do
    as_actor(staff) { 4.times { |i| @order.update!(notes: "note #{i}") } }

    get audit.record_history_path(record_type: "Order", record_id: @order.id, format: :csv)
    times = csv_from(response).map { |r| r["occurred_at"] }

    expect(times).to eq(times.sort.reverse)
  end

  it "renders jsonb and text[] as JSON, not as Ruby inspect output" do
    get audit.record_history_path(record_type: "Order", record_id: @order.id, format: :csv)
    row = csv_from(response).first

    expect { JSON.parse(row["diff"]) }.not_to raise_error
    expect(JSON.parse(row["changed_columns"])).to be_an(Array)
  end

  it "honours the screen's date range" do
    get audit.records_path, params: { format: :csv }
    get audit.record_path("Order", format: :csv, from: "2001-01-01", to: "2001-01-02")

    expect(csv_from(response).size).to eq(0)
  end

  # Action ids contain dots, so `/audit/actions/order.created.csv` is recognised
  # as `id: "order.created.csv"` with no format -- the greedy id constraint eats
  # the extension and the screen quietly serves HTML for an action that does not
  # exist. A header-only assertion passes against that, so this asserts rows.
  it "exports the event layer for an action whose id contains dots" do
    as_actor(staff) { AuditLog.notify("order.created", order_id: @order.id) }

    get "/audit/actions/order.created", params: { format: "csv" }

    expect(response.media_type).to eq("text/csv")
    rows = csv_from(response)
    expect(rows.headers).to include("summary", "caused_by_request_id")
    expect(rows.size).to eq(1)
    expect(rows.first["action"]).to eq("order.created")
  end

  it "does not mistake a dotted action id for a format" do
    expect(Rails.application.routes.recognize_path("/audit/actions/order.created"))
      .to include(id: "order.created")
  end

  # The export is a bulk read of the audit log, so it must not be a way around
  # the screen's authorization. Rails renders the authorize hook's RoutingError
  # as a 404 rather than a 403, deliberately -- see audit_ui_spec.
  it "is behind the same authorization as the screen" do
    sign_out
    sign_in create_user(name: "Jane", email: "jane@example.com", role: "manager")

    get audit.record_history_path(record_type: "Order", record_id: @order.id, format: :csv)

    expect(response).to have_http_status(:not_found)
    expect(response.media_type).not_to eq("text/csv")
  end
end
