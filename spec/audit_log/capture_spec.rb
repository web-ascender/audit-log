# frozen_string_literal: true

require "rails_helper"

# Turning layer 1 off and back on without losing what it recorded. DESIGN §25.
#
# WHAT THIS SPEC EXISTS TO PREVENT, in the family the others belong to: that
# capture stops without saying so. Every example below is one of the two ways
# that could happen -- the audit log goes quiet and the forcing function still
# passes, or capture resumes under DIFFERENT arguments than it had and every row
# written afterwards is subtly wrong (a `record_type` naming the wrong model, an
# exclusion silently dropped so a password column starts landing in a diff).
#
# The whole suite runs with transactional fixtures, which is not incidental here:
# DROP TRIGGER and COMMENT ON TABLE are transactional in PostgreSQL, so every
# example that detaches all six triggers has them back at rollback. That is also
# the property the generated migration relies on to be safely re-runnable.
RSpec.describe AuditLog::Capture do
  let(:user) { create_user }

  def trigger_defs
    ActiveRecord::Base.connection.select_rows(<<~SQL).to_h
      SELECT t.tgname, pg_get_triggerdef(t.oid)
      FROM   pg_trigger t
      JOIN   pg_class c ON c.oid = t.tgrelid
      JOIN   pg_namespace n ON n.oid = c.relnamespace
      WHERE  NOT t.tgisinternal
        AND  t.tgname LIKE '%\\_audit'
        AND  n.nspname = current_schema()
    SQL
  end

  # The trigger name is DERIVED from the table, never stored -- which is why
  # `Capture.snapshot` omits it and this helper works on both shapes (the catalog
  # read, which carries it, and the marker payload, which does not).
  def detach_all!(snapshot)
    snapshot.each do |t|
      ActiveRecord::Base.connection.execute("DROP TRIGGER #{t[:table]}_audit ON #{t[:table]}")
    end
  end

  def reattach!(snapshot)
    migration = ActiveRecord::Migration.new
    migration.extend(AuditLog::MigrationHelpers)
    ActiveRecord::Migration.suppress_messages do
      snapshot.each do |t|
        migration.attach_audit_trigger t[:table],
          model: t[:model], exclude: t[:excluded], dimensions: t[:dimensions]
      end
    end
  end

  describe ".attached" do
    subject(:attached) { described_class.attached }

    # tgargs is a bytea of null-terminated strings, and it is read rather than
    # `pg_get_triggerdef` parsed: the model name is an arbitrary string this
    # library never validated, so a regex over the rendered DDL has a quoting hole
    # that this does not.
    it "reads the model and the merged exclusion list off the catalog" do
      users = attached.find { |t| t[:table] == "users" }

      expect(users[:model]).to eq("User")
      expect(users[:trigger]).to eq("users_audit")
      expect(users[:excluded]).to include("created_at", "password_digest")
    end

    # THE GUARD THAT MATTERS: `tgnargs >= 3`. The bytea ends with a null
    # terminator, so splitting runs off the end and leaves an empty string --
    # without the guard every table looks as though it declared a facet, and
    # re-attaching would pass a third argument the original did not have.
    it "distinguishes a declared facet list from the null terminator" do
      expect(attached.find { |t| t[:table] == "orders" }[:dimensions])
        .to eq(%w[customer_id created_by_id status])
      expect(attached.find { |t| t[:table] == "users" }[:dimensions]).to eq([])
    end

    it "finds every audited table and nothing else" do
      expect(attached.map { |t| t[:table] })
        .to contain_exactly("customers", "line_items", "orders", "products", "shipments", "users")
    end
  end

  # THE CYCLE. This is the claim the whole feature rests on: what comes back is
  # what was there, not an approximation of it.
  describe "the disable/enable cycle" do
    it "restores every trigger definition byte for byte" do
      before  = trigger_defs
      snapshot = described_class.attached

      detach_all!(snapshot)
      expect(trigger_defs).to be_empty

      reattach!(snapshot)
      expect(trigger_defs).to eq(before)
    end

    # Passing the MERGED list back as `exclude:` is what makes the above exact.
    # `attach_audit_trigger` computes `(defaults + exclude).uniq`, so the merged
    # list reproduces the original argument -- and still reproduces every
    # exclusion the table had if a default is later removed from the config.
    # Subtracting today's defaults to recover the original `exclude:` reads
    # better and drops an exclusion the day somebody edits that list.
    it "survives a default_excluded_columns that has changed since the attach" do
      before   = trigger_defs["products_audit"]
      snapshot = described_class.attached

      detach_all!(snapshot)
      allow(AuditLog.config).to receive(:default_excluded_columns).and_return(%w[created_at])
      reattach!(snapshot)

      expect(trigger_defs["products_audit"]).to eq(before)
    end

    it "records nothing while detached, and records again afterwards" do
      snapshot = described_class.attached
      detach_all!(snapshot)

      expect { as_actor(user) { create_product } }
        .not_to change(AuditLog::Change, :count)

      reattach!(snapshot)

      expect { as_actor(user) { create_product } }
        .to change(AuditLog::Change, :count)
    end

    # The tables, the partitions and the rows are untouched -- the entire point of
    # detaching rather than uninstalling. `Schema.uninstall!` is the other thing
    # and it DROPs both tables.
    it "leaves the audit tables, their partitions and their rows alone" do
      as_actor(user) { create_product }
      rows       = AuditLog::Change.count
      partitions = AuditLog::Partitions.list

      detach_all!(described_class.attached)

      expect(AuditLog::Change.count).to eq(rows)
      expect(AuditLog::Partitions.list).to eq(partitions)
    end

    # Layer 2 is application code and this does not reach it. Deliberate: a
    # narrated gap is a control, a blank one is a finding, and there is no
    # `config.enabled = false` for the reason `retention_action` is gone.
    it "does not stop layer 2" do
      detach_all!(described_class.attached)

      expect { as_actor(user) { AuditLog.notify("order.deleted") } }
        .to change(AuditLog::Event, :count).by(1)
    end
  end

  describe "the marker" do
    let(:snapshot) { described_class.attached }

    it "is absent until capture is disabled" do
      expect(described_class).not_to be_disabled
      expect(described_class.status).to be_nil
    end

    it "carries the reason, the timestamp and the whole snapshot" do
      as_actor(user) { described_class.disable!(reason: "DSR-99", triggers: snapshot) }

      expect(described_class).to be_disabled
      expect(described_class.status).to include("reason" => "DSR-99")
      expect(described_class.status["disabled_at"]).to be_present
      expect(described_class.snapshot.map { |t| t[:table] }).to eq(snapshot.map { |t| t[:table] })
    end

    # THE RECOVERY PATH's whole reason for existing: once the triggers are gone
    # the catalog cannot say what they were, so if the migration holding the same
    # list has been squashed or deleted, this is the only remaining record.
    # Reconstructing model names from table names is the sniffing RecordLabel
    # refuses to do, in a place where it would mislabel every row written after.
    it "is enough on its own to re-attach exactly what was there" do
      before = trigger_defs
      as_actor(user) { described_class.disable!(reason: "DSR-99", triggers: snapshot) }
      detach_all!(snapshot)

      reattach!(described_class.snapshot)

      expect(trigger_defs).to eq(before)
    end

    it "goes on the parent, where no partition path can clear it" do
      as_actor(user) { described_class.disable!(reason: "DSR-99", triggers: snapshot) }

      AuditLog::Partitions.clear_frozen_marker!(AuditLog::Partitions.list)

      expect(described_class).to be_disabled
    end

    it "is cleared by enable!" do
      as_actor(user) { described_class.disable!(reason: "DSR-99", triggers: snapshot) }
      as_actor(user) { described_class.enable! }

      expect(described_class).not_to be_disabled
    end

    # An unreadable marker reports "disabled, no detail" rather than crashing a
    # coverage report -- the same posture as an unparseable RETIRED_MARKER, which
    # is skipped rather than guessed at. `snapshot` then comes back EMPTY, which
    # is what makes the enable generator refuse instead of inventing a list.
    it "reports a corrupt payload as present with no detail" do
      ActiveRecord::Base.connection.execute(
        "COMMENT ON TABLE audit_changes IS #{ActiveRecord::Base.connection.quote("#{described_class::MARKER} not json")}"
      )

      expect(described_class).to be_disabled
      expect(described_class.status).to eq({})
      expect(described_class.snapshot).to eq([])
    end
  end

  # THE NARRATION IS NOT OPTIONAL. `EventSubscriber#emit` is `Registry[name] or
  # return`, so an unregistered action writes nothing and reports nothing -- and a
  # deliberate gap in an audit log with nothing accounting for it is the worst
  # outcome available here. So it raises rather than falling silent, which is the
  # one place this library treats a missing registry entry as an error.
  describe "the narration guard" do
    it "writes an event naming the reason and the tables" do
      expect { as_actor(user) { described_class.disable!(reason: "cost", triggers: described_class.attached) } }
        .to change(AuditLog::Event, :count).by(1)

      event = AuditLog::Event.order(:occurred_at).last
      expect(event.action).to eq("audit.capture_disabled")
      expect(event.summary).to include("cost")
      expect(event.metadata["tables"]).to include("orders")
    end

    it "narrates the resume with the date it was disabled" do
      as_actor(user) { described_class.disable!(reason: "cost", triggers: described_class.attached) }
      disabled_at = described_class.status["disabled_at"]

      as_actor(user) { described_class.enable! }

      event = AuditLog::Event.order(:occurred_at).last
      expect(event.action).to eq("audit.capture_resumed")
      expect(event.summary).to include(disabled_at)
    end

    it "refuses to disable capture when the action has no registry entry" do
      entry = AuditLog::Registry.entries.delete("audit.capture_disabled")

      expect { described_class.disable!(reason: "cost", triggers: described_class.attached) }
        .to raise_error(AuditLog::Error, /no registry entry.*would be the only evidence/m)
      expect(described_class).not_to be_disabled
    ensure
      AuditLog::Registry.entries["audit.capture_disabled"] = entry
    end

    it "refuses to resume without one either" do
      entry = AuditLog::Registry.entries.delete("audit.capture_resumed")
      as_actor(user) { described_class.disable!(reason: "cost", triggers: described_class.attached) }

      expect { described_class.enable! }.to raise_error(AuditLog::Error, /no registry entry/)
      expect(described_class).to be_disabled
    ensure
      AuditLog::Registry.entries["audit.capture_resumed"] = entry
    end

    it "requires a reason, and something to disable" do
      expect { described_class.disable!(reason: " ", triggers: described_class.attached) }
        .to raise_error(ArgumentError, /reason/)
      expect { described_class.disable!(reason: "x", triggers: []) }
        .to raise_error(ArgumentError, /no triggers/)
    end
  end

  # THE THIRD STATE. Without it a disabled audit log fails coverage with
  # "Untracked tables: ... Add attach_audit_trigger to a migration" -- true,
  # useless, and the wrong repair, since `audit_log:trigger` SUCCEEDS while
  # capture is disabled and leaves the marker standing over a schema that no
  # longer matches it.
  describe "AuditLog::Coverage" do
    it "is not ok, and says capture is disabled rather than naming migrations" do
      as_actor(user) do
        AuditLog::Capture.disable!(reason: "staging", triggers: AuditLog::Capture.attached)
      end
      detach_all!(AuditLog::Capture.snapshot)

      coverage = AuditLog::Coverage.new

      expect(coverage).to be_capture_disabled
      expect(coverage).not_to be_ok
      expect(coverage.report).to include("CAPTURE IS DISABLED", "staging")
      expect(coverage.report).not_to include("Add attach_audit_trigger")
    end

    # A disabled log must never come back OK, for the reason `retention_action`
    # was removed: an escape hatch that satisfies the forcing function while the
    # thing it forces is switched off is weaker than no hatch.
    it "fails even when every table is otherwise accounted for" do
      as_actor(user) do
        AuditLog::Capture.disable!(reason: "staging", triggers: AuditLog::Capture.attached)
      end

      expect(AuditLog::Coverage.new.missing).to be_empty
      expect(AuditLog::Coverage.new).not_to be_ok
    end
  end
end
