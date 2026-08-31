# frozen_string_literal: true

require "rails_helper"

# The gemspec claims `rails ~> 8.0`, and the two ends of that range emit layer 2
# through DIFFERENT transports: Rails 8.1 has `Rails.event`, 8.0 does not, and
# AuditLog.notify falls back to calling the subscriber directly.
#
# Until CI grew a Rails 8.0 leg the fallback was an untested branch guarding an
# unverified claim -- the CHANGELOG listed it as a known gap for exactly that
# reason. These examples are what make the leg mean something: without them the
# 8.0 run proves only that nothing raised, not that the branch it exists to cover
# was the one taken.
RSpec.describe "layer 2's event transport" do
  let(:rails_has_event_reporter) { Rails.gem_version >= Gem::Version.new("8.1") }

  # Which branch AuditLog.notify takes is decided by the Rails under test, not by
  # configuration -- so assert the branch matches the Rails, in both directions.
  # A `defined?` that silently answers false on 8.1 would disable Rails.event
  # integration everywhere and nothing else in this suite would notice.
  it "uses Rails.event where it exists, and the subscriber directly where it does not" do
    expect(Rails.respond_to?(:event)).to eq(rails_has_event_reporter)
  end

  # The property that actually matters, and it is transport-independent: an
  # emitted action lands in audit_events either way. This is the assertion the
  # 8.0 leg was added to run.
  it "writes an audit_events row on whichever transport this Rails provides" do
    actor = create_user

    expect {
      as_actor(actor) do
        AuditLog.notify("order.submitted", order_id: 4321, reference: "SO-1", customer_name: "X",
                                           line_count: 1, total_cents: 100)
      end
    }.to change { AuditLog::Event.where(action: "order.submitted").count }.by(1)

    event = AuditLog::Event.where(action: "order.submitted").last
    expect(event.metadata["order_id"]).to eq(4321)
    expect(event.actor_id).to eq(actor.id)
  end

  # Rails.event.raise_on_error = true is set in the engine initializer because
  # EventReporter otherwise SWALLOWS subscriber exceptions -- a failed audit write
  # would vanish while the change rows it describes commit anyway. On 8.0 there is
  # no reporter to swallow anything, so the direct call propagates natively.
  # Either way a broken subscriber must not fail silently.
  #
  # Stubbed on the INSTANCE method rather than on `.new`: on 8.1 the subscriber
  # was instantiated once at boot and registered with the reporter, so stubbing
  # the constructor reaches nothing and this example would pass for the wrong
  # reason -- which is exactly what it did on first writing.
  it "does not swallow a subscriber failure" do
    allow_any_instance_of(AuditLog::EventSubscriber)
      .to receive(:emit).and_raise(RuntimeError, "subscriber down")

    expect { AuditLog.notify("order.submitted", order_id: 1) }
      .to raise_error(RuntimeError, /subscriber down/)
  end
end
