# frozen_string_literal: true

require "rails_helper"

# The actor label is the one label in this library that is STORED. Everything
# else about labelling -- association captions, record identity cells -- is
# resolved live at display time and annotates an id that stays on the screen
# beside it. This one replaces the identity in its own column, permanently, on
# every row written from the moment it is configured (R6).
#
# So the property these examples defend is not "the string is pretty". It is
# that the host app has a way to say what auditors see WITHOUT that being the
# same decision as what the rest of its UI shows, and that a host which said
# nothing still gets something readable rather than an Object#inspect.
RSpec.describe AuditLog::ActorLabel do
  # The default resolver, reached through a fresh Configuration rather than
  # AuditLog.config -- spec/dummy overrides actor_label_resolver, which is what
  # left this chain untested until now.
  describe "the default chain" do
    def default_label_for(actor)
      AuditLog::Configuration.new.actor_label_resolver.call(actor)
    end

    # The same head as AuditLog::RecordLabel, and for the same reason: a model
    # may need to say something to auditors other than what it says everywhere
    # else. It matters more here than it does there, because there the everyday
    # label merely annotates a visible id and here it is frozen onto the row.
    it "prefers to_audit_label over to_label" do
      actor = Class.new do
        def to_audit_label = "Support agent #4471"
        def to_label       = "Jane Doe <jane@example.com>"
      end.new

      expect(default_label_for(actor)).to eq("Support agent #4471")
    end

    it "falls back to to_label, the ordinary convention" do
      actor = Class.new { def to_label = "Jane Doe <jane@example.com>" }.new

      expect(default_label_for(actor)).to eq("Jane Doe <jane@example.com>")
    end

    it "assembles a name and email for an actor that heard of neither hook" do
      actor = Class.new do
        def name  = "Jane Doe"
        def email = "jane@example.com"
      end.new

      expect(default_label_for(actor)).to eq("Jane Doe <jane@example.com>")
    end

    # The deliberate divergence from RecordLabel, whose chain ends in nil so an
    # un-opted-in model leaves the cell byte-identical. Here the label IS the
    # column, so it must terminate in something an auditor can read.
    it "ends in Class #id rather than nil, unlike RecordLabel" do
      klass = Class.new do
        def self.name = "ApiKey"
        def id = 7
      end

      expect(default_label_for(klass.new)).to eq("ApiKey #7")
      expect(AuditLog::RecordLabel.for(klass.new)).to be_nil
    end
  end

  describe ".for" do
    # Documented in the method itself: the resolver is never handed nil, so a
    # host app's lambda does not have to defend against it.
    it "returns nil for a nil actor without calling the resolver" do
      called = false
      allow(AuditLog.config).to receive(:actor_label_resolver)
        .and_return(lambda { |_actor|
          called = true
          "never"
        })

      expect(described_class.for(nil)).to be_nil
      expect(called).to be(false)
    end

    it "truncates to the stored column's width" do
      actor = Class.new { def to_label = "x" * 500 }.new

      expect(described_class.for(actor).length).to eq(AuditLog::ActorLabel::MAX_LENGTH)
    end

    it "returns nil rather than an empty string for a blank label" do
      actor = Class.new { def to_label = "   " }.new

      expect(described_class.for(actor)).to be_nil
    end
  end

  # A nil actor stores NULL and reads as "System" at display time, never the
  # other way round: storing the word would make a scheduled job and a console
  # session that forgot to identify itself indistinguishable forever.
  describe ".display" do
    it "prefers the snapshotted label" do
      expect(described_class.display("User", 1, "Jane Doe")).to eq("Jane Doe")
    end

    it "falls back to the bare identifier when no label was snapshotted" do
      expect(described_class.display("User", 1, nil)).to eq("User #1")
    end

    it "renders a NULL actor as System" do
      expect(described_class.display(nil, nil, nil)).to eq("System")
    end
  end

  describe ".linkable?" do
    it "is false for a NULL actor, which has no activity page" do
      expect(described_class.linkable?(nil, nil)).to be(false)
      expect(described_class.linkable?("User", 1)).to be(true)
    end
  end
end
