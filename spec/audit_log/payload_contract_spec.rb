# frozen_string_literal: true

require "rails_helper"

# The registry's `requires:` is the third point that makes the two halves of a
# registered action agree. Without it, the call site's keys and the `p[...]`
# reads in the entry are checked by nothing, and a typo on EITHER side renders a
# gap in a sentence that is frozen at emit time and cannot be repaired.
#
# So what this pins is that the gap becomes loud, that it becomes loud INSIDE the
# transaction, and that the three deliberate softenings stay soft: extras pass,
# a declared-but-nil value is supplied, and an entry with no `requires:` is
# unchecked exactly as before.
RSpec.describe "the registry payload contract" do
  let(:user) { create_user }

  # Remove only what these examples added. NOT Rails.application.reloader.reload!,
  # which unloads the engine's Zeitwerk-managed app/** constants mid-suite and
  # takes 26 unrelated examples down with it -- verified, not assumed.
  after { AuditLog::Registry.entries.delete("test.action") }

  def register(**kwargs)
    AuditLog::Registry.register("test.action",
      summary: ->(p) { "did #{p[:thing]}" }, **kwargs)
  end

  it "raises when a required key is missing, naming the key and both causes" do
    register(requires: %i[thing count])

    expect { as_actor(user) { AuditLog.notify("test.action", thing: "x") } }
      .to raise_error(AuditLog::MissingPayloadKeys, /omitted :count.*misspelled it/m)
  end

  it "passes when every required key is present" do
    register(requires: %i[thing])

    expect { as_actor(user) { AuditLog.notify("test.action", thing: "x") } }
      .to change(AuditLog::Event, :count).by(1)
  end

  # Decision 5: extras are not an error, and they are still persisted. Payloads
  # legitimately grow, and a call-site typo is already caught by the missing half.
  it "passes extra keys through and stores them" do
    register(requires: %i[thing])

    as_actor(user) { AuditLog.notify("test.action", thing: "x", extra: 1, more: "two") }

    expect(AuditLog::Event.last.metadata).to eq("thing" => "x", "extra" => 1, "more" => "two")
  end

  # Decision 4: key presence, not value presence. metadata is stored `.compact`ed,
  # so a deliberate nil and a forgotten key produce an identical row -- this is
  # the only place the distinction can still survive.
  it "treats a declared key with a nil value as supplied" do
    register(requires: %i[thing])

    expect { as_actor(user) { AuditLog.notify("test.action", thing: nil) } }
      .to change(AuditLog::Event, :count).by(1)
    expect(AuditLog::Event.last.metadata).to eq({})
  end

  # Decision 2: opt-in per entry, which is what keeps this from being a landmine.
  it "checks nothing for an entry that declares no requires:" do
    register

    expect { as_actor(user) { AuditLog.notify("test.action") } }
      .to change(AuditLog::Event, :count).by(1)
  end

  it "accepts a bare symbol and strings, normalising both" do
    register(requires: :thing)
    expect(AuditLog::Registry["test.action"].requires).to eq(%i[thing])

    register(requires: %w[thing count])
    expect(AuditLog::Registry["test.action"].requires).to eq(%i[thing count])
  end

  # The check runs in EventSubscriber#emit, which is inside the caller's
  # transaction. Same position the engine takes with raise_on_error: a broken
  # narrative rolls the change back rather than committing beside a sentence
  # with a hole in it.
  it "rolls the business change back rather than committing a holed sentence" do
    register(requires: %i[thing count])
    order = Order.create!(customer: create_customer, created_by: user)

    expect {
      as_actor(user) do
        AuditLog.audited("test.action", on: order, thing: "x") do
          order.update!(status: "submitted")
        end
      end
    }.to raise_error(AuditLog::MissingPayloadKeys)

    expect(order.reload.status).to eq("draft")
  end

  it "reaches audited's collected half, not just its keywords" do
    register(requires: %i[thing count])
    order = Order.create!(customer: create_customer, created_by: user)

    expect {
      as_actor(user) do
        AuditLog.audited("test.action", on: order, thing: "x") { |audit| audit[:count] = 2 }
      end
    }.to change(AuditLog::Event, :count).by(1)
  end

  # The dummy app declares a contract for most of its actions and leaves exactly
  # two undeclared on purpose, so both paths are exercised by an app rather than
  # only by the examples above. Neither is an oversight and neither is to be
  # "finished":
  #
  #   order.deleted        -- the only action that can be emitted with an EMPTY
  #                           payload, which is the state shared/_event_payload
  #                           renders as nothing and audit_ui_spec asserts on.
  #   audit.capture_resumed -- renders from nothing by design (DESIGN §25). Its
  #                           only payload key, disabled_at, is absent whenever the
  #                           marker was unreadable, so requiring it would
  #                           contradict a summary that is complete without it --
  #                           the same reason `columns` is not required by
  #                           audit.redaction.
  describe "the dummy app's own entries" do
    it "declares a payload contract for all but the two deliberate exceptions" do
      declared, undeclared = AuditLog::Registry.entries.values.partition(&:requires)

      expect(undeclared.map(&:action)).to contain_exactly("order.deleted", "audit.capture_resumed")
      expect(declared.size).to be >= 14
    end

    # A declaration listing a key no call site sends would fail at emit time, in
    # production, on a path nobody exercised. These are the two actions this gem
    # itself emits, so its own payloads and the host's declaration must agree.
    it "is satisfied by the payloads the library itself emits" do
      %w[audit.bypass audit.bypass_completed].each do |action|
        expect(AuditLog::Registry[action].requires).to include(:reason)
      end
    end
  end

  # THE NAMING CONVENTION -- every id key in a payload names its type,
  # `order_id:` and never a bare `id:`, including on an action whose subject IS
  # that record. DESIGN §7 carries the three consequences; the short version is
  # that a bare `id` cannot be declared as a dimension, so the record's own
  # events fall off its own facet feed while a record timeline still shows them.
  #
  # DELIBERATELY NOT ENFORCED AT RUNTIME, and these examples are not a step
  # toward it: a bare `id` renders, stores and queries perfectly and only reads
  # worse, which makes it a convention rather than an invariant. §23's line --
  # the migration-time facet-column check earns its exception because a typo
  # there records nothing forever and never says why.
  #
  # What IS checkable is that the library never demonstrates the opposite. Four
  # documents state the rule (README "Payload rules", DESIGN §7, CLAUDE.md,
  # llms.txt) and the two files below are the ones an adopter COPIES FROM -- the
  # reference app they read and the initializer the install generator writes into
  # their repository. Those are what rot silently.
  describe "payload key naming (DESIGN §7)" do
    it "declares no bare :id in any entry's requires: or dimensions:" do
      offenders = AuditLog::Registry.entries.values.select { |entry|
        Array(entry.requires).include?(:id) || Array(entry.dimensions).include?(:id)
      }.map(&:action)

      expect(offenders).to be_empty,
        "these entries declare a bare :id payload key -- name it for its type " \
        "(order_id, customer_id), DESIGN §7: #{offenders.join(", ")}"
    end

    # `p[:id]` and not `%i[id]`, because the README and the install template both
    # spell the counter-example on purpose while warning against it. This greps
    # the two files whose examples get copied, never the prose that explains them.
    it "reads no bare p[:id] in the dummy app or the shipped install template" do
      root  = Pathname(AuditLog::GEM_ROOT)
      files = [root.join("spec/dummy/config/initializers/audit_log.rb"),
               root.join("lib/generators/audit_log/install/templates/initializer.rb.tt")]

      files.each { |f| expect(f).to exist }
      offenders = files.select { |f| f.read.match?(/\bp\[:id\]/) }
                       .map { |f| f.relative_path_from(root).to_s }

      expect(offenders).to be_empty,
        "a payload key must name its type -- p[:order_id], not p[:id], DESIGN §7: " \
        "#{offenders.join(", ")}"
    end
  end
end
