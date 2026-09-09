# frozen_string_literal: true

require "rails_helper"

# The three spellings of a recorded identity, and the rule that every screen
# uses one of them rather than interpolating its own. Before this module there
# were seven copies of `"#{type} ##{id}"` and nothing made them agree -- the
# Changes tab and the Timeline tab of the same record screen drifted apart the
# first time one was edited.
RSpec.describe AuditLog::Identity do
  describe "the three forms" do
    # The type is already established by the column, so only the id needs saying.
    it "annotates a bare id where the context has named the type" do
      expect(described_class.annotation(51)).to eq("(id: 51)")
    end

    it "renders a standalone identity with its type" do
      expect(described_class.for("Order", 6064)).to eq("Order (id: 6064)")
    end

    # DESIGN §11.8: the label is resolved live from current state, the id is what
    # the log recorded. Rendering only the label turns an audit screen into a
    # report of current state.
    it "keeps the id beside a live-resolved label" do
      expect(described_class.labelled("Grommet 10mm", "Product", 51))
        .to eq("Grommet 10mm (Product id: 51)")
    end

    it "falls back to the bare identity when the host labels nothing" do
      expect(described_class.labelled(nil, "Product", 51)).to eq("Product (id: 51)")
      expect(described_class.labelled("", "Product", 51)).to eq("Product (id: 51)")
    end

    # The `#` prefix is what host applications use for their OWN identifier -- an
    # order number, an invoice number, a ticket reference. On an audit screen a
    # reader cannot tell that apart from a primary key, and these strings exist
    # to be unmistakably what the log recorded.
    it "never prefixes an id with #" do
      [described_class.annotation(1), described_class.for("Order", 1),
       described_class.labelled("SO-1", "Order", 1)].each do |rendered|
        expect(rendered).not_to include("#")
      end
    end
  end

  # The forcing function. A new screen that hand-rolls the string is how the two
  # tabs disagreed in the first place, and a grep is the only thing that notices.
  describe "the one definition" do
    SOURCE_GLOBS = %w[app/**/*.rb app/**/*.erb lib/**/*.rb lib/**/*.tt].freeze

    # BOTH spellings. The first version of this guard looked for Ruby
    # interpolation only, and missed `<%= @record_type %> #<%= @record_id %>` in
    # the heading of the very screen whose two tabs had disagreed.
    it "is the only place that interpolates a type and an id together" do
      root = Pathname.new(AuditLog::GEM_ROOT)
      offenders = SOURCE_GLOBS.flat_map { |glob| Pathname.glob(root.join(glob)) }
        .reject { |path| path.basename.to_s == "identity.rb" }
        .select { |path| path.read.match?(/\#\#\{|\#<%=/) }
        .map { |path| path.relative_path_from(root).to_s }

      expect(offenders).to be_empty, <<~MSG
        These interpolate an id directly instead of going through
        AuditLog::Identity:

          #{offenders.join("\n  ")}

        Use Identity.for(type, id), Identity.labelled(label, type, id) or
        Identity.annotation(id). Seven hand-rolled copies is how the Changes tab
        and the Timeline tab of one record screen came to spell the same
        recorded fact two different ways.
      MSG
    end
  end
end
