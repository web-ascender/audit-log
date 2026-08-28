# frozen_string_literal: true

require "rails_helper"

# DESIGN §13, ROLLOUT Q5. The tension is R7 (immutable) against an erasure
# request, and the resolution is that STRUCTURE is permanent while VALUES are
# not. Nearly every example here is really asserting one half of that sentence.
RSpec.describe AuditLog::Redaction do
  let(:actor) { create_user(name: "Mei Chen", email: "mei@example.com", role: "auditor") }

  before do
    @customer = as_actor(create_user) { create_customer }
    as_actor(create_user) do
      @customer.update!(name: "Jane Q. Public", email: "jane@private.example")
      @customer.update!(status: "dormant")
    end
  end

  def diffs_for(customer = @customer)
    AuditLog::Change.for_record("Customer", customer.id).pluck(:diff)
  end

  describe ".redact_record!" do
    it "replaces the values but keeps every column key" do
      before_keys = diffs_for.map(&:keys)

      described_class.redact_record!(record_type: "Customer", record_id: @customer.id,
                                     reason: "DSR-1182", actor: actor)

      expect(diffs_for.map(&:keys)).to eq(before_keys)
      expect(diffs_for.flat_map(&:values).flatten.uniq).to all(match(/\A\[redacted .* per DSR-1182\]\z/))
    end

    # The whole design in one assertion: "the email address was changed at 14:02
    # by Jane" stays provable after the address itself is gone.
    it "keeps changed_columns intact, so the structural record survives" do
      before_columns = AuditLog::Change.for_record("Customer", @customer.id)
                                       .pluck(:changed_columns)

      described_class.redact_record!(record_type: "Customer", record_id: @customer.id,
                                     reason: "DSR-1182")

      expect(AuditLog::Change.for_record("Customer", @customer.id).pluck(:changed_columns))
        .to eq(before_columns)
    end

    it "keeps who, when and which request" do
      row = AuditLog::Change.for_record("Customer", @customer.id).newest_first.first
      before = row.slice(:occurred_at, :actor_type, :actor_id, :actor_label, :request_id, :operation)

      described_class.redact_record!(record_type: "Customer", record_id: @customer.id,
                                     reason: "DSR-1182")

      expect(row.reload.slice(:occurred_at, :actor_type, :actor_id, :actor_label,
                              :request_id, :operation)).to eq(before)
    end

    it "redacts only the named columns and leaves the rest readable" do
      described_class.redact_record!(record_type: "Customer", record_id: @customer.id,
                                     columns: %w[email], reason: "DSR-1182")

      all = diffs_for.reduce({}) { |acc, d| acc.merge(d) }
      expect(all["email"].join).to include("redacted")
      expect(all["name"].join).not_to include("redacted")
      expect(all["status"].join).not_to include("redacted") if all.key?("status")
    end

    it "does not touch another record's rows" do
      other = as_actor(create_user) { create_customer }
      as_actor(create_user) { other.update!(name: "Untouched Ltd") }

      described_class.redact_record!(record_type: "Customer", record_id: @customer.id,
                                     reason: "DSR-1182")

      expect(diffs_for(other).flat_map(&:values).flatten.join).not_to include("redacted")
    end

    # Regulators want a record that data was removed and why. A silent hole is
    # the thing to avoid.
    it "narrates itself as an audited action" do
      expect {
        described_class.redact_record!(record_type: "Customer", record_id: @customer.id,
                                       reason: "DSR-1182", actor: actor)
      }.to change { AuditLog::Event.for_action("audit.redaction").count }.by(1)

      event = AuditLog::Event.for_action("audit.redaction").newest_first.first
      expect(event.summary).to include("DSR-1182").and include("Customer ##{@customer.id}")
      expect(event.summary).to include("Mei Chen")
      expect(event.summary).not_to include("jane@private.example")
    end

    it "refuses without a written reason" do
      expect {
        described_class.redact_record!(record_type: "Customer", record_id: @customer.id, reason: " ")
      }.to raise_error(AuditLog::Error, /written reason/)
    end

    # If the UPDATE fails, the log must not claim a redaction happened.
    it "writes the narration and the redaction in one transaction" do
      allow(described_class).to receive(:redact_diffs!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect {
        begin
          described_class.redact_record!(record_type: "Customer", record_id: @customer.id,
                                         reason: "DSR-1182")
        rescue ActiveRecord::StatementInvalid
          nil
        end
      }.not_to change { AuditLog::Event.for_action("audit.redaction").count }
    end

    it "clears the event payload and summary for the subject" do
      as_actor(create_user) do
        AuditLog.notify("customer.updated", customer_id: @customer.id,
                                            name: "Jane Q. Public", fields: %w[email])
      end

      described_class.redact_record!(record_type: "Customer", record_id: @customer.id,
                                     reason: "DSR-1182")

      event = AuditLog::Event.for_action("customer.updated").newest_first.first
      expect(event.summary).to include("redacted")
      expect(event.metadata).to eq({})
      expect(event.action).to eq("customer.updated")   # structure survives
      expect(event.occurred_at).to be_present
    end

    # The UI has to distinguish "no payload" from "payload redacted", and the
    # marker is the only trace on the row. Two independent spellings of it would
    # drift the first time the wording changed, and the screen would go back to
    # rendering an erasure as an absence.
    it "recognises its own marker" do
      expect(described_class.marker?(described_class.marker_for("DSR-1182"))).to be true
    end

    it "does not mistake an ordinary summary for one" do
      expect(described_class.marker?("Submitted order SO-1 for Acme")).to be false
      expect(described_class.marker?("[redacted] by hand")).to be false
      expect(described_class.marker?(nil)).to be false
    end

    it "is idempotent" do
      described_class.redact_record!(record_type: "Customer", record_id: @customer.id, reason: "DSR-1182")
      first = diffs_for

      described_class.redact_record!(record_type: "Customer", record_id: @customer.id, reason: "DSR-1182")
      expect(diffs_for).to eq(first)
    end
  end

  describe ".redact_actor!" do
    # Pseudonymization, not deletion: the person stops being named but their
    # activity stays attributable and countable, which is what the log is for.
    it "replaces the label and keeps the identifier" do
      subject_user = create_user(name: "Raj Patel", email: "raj@example.com")
      as_actor(subject_user) { create_product }

      described_class.redact_actor!(actor_type: "User", actor_id: subject_user.id,
                                    reason: "DSR-1183")

      rows = AuditLog::Change.by_actor("User", subject_user.id)
      expect(rows.count).to be_positive
      expect(rows.pluck(:actor_label).uniq).to all(include("DSR-1183"))
      expect(rows.pluck(:actor_id).uniq).to eq([subject_user.id])
    end
  end

  describe ".preview" do
    it "reports what would be touched without touching it" do
      preview = described_class.preview(record_type: "Customer", record_id: @customer.id)

      expect(preview[:changes]).to be_positive
      expect(preview[:columns]).to include("email")
      expect(diffs_for.flat_map(&:values).flatten.join).not_to include("redacted")
    end
  end
end
