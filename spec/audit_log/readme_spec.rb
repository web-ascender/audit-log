# frozen_string_literal: true

require "rails_helper"

# The README is the only documentation an adopting app reads, and it is long
# enough now to have a table of contents -- which means it is long enough for
# that table to go stale silently.
#
# It already did, twice in one afternoon: a link to a "The partition lifecycle"
# heading that no longer existed, and two renamed headings the contents block
# still pointed at. Neither breaks anything a spec was watching, and neither is
# visible until somebody clicks.
RSpec.describe "README.md" do
  README = Pathname(AuditLog::GEM_ROOT).join("README.md")

  # GitHub's own slug rules, near enough: strip formatting, downcase, drop
  # punctuation, hyphenate spaces.
  def self.slug(text)
    text = text.gsub(/`([^`]*)`/, '\1').gsub(/\*\*?([^*]*)\*\*?/, '\1')
    text.downcase.gsub(/[^\w\s-]/, "").strip.gsub(/\s+/, "-")
  end

  # Fenced code blocks contain `#` comments that are not headings.
  def self.headings(body)
    in_code = false
    body.lines.filter_map do |line|
      in_code = !in_code if line.start_with?("```")
      next if in_code

      m = line.match(/^(\#{1,6}) (.+)$/)
      [m[1].length, m[2].strip] if m
    end
  end

  let(:body)     { README.read }
  let(:headings) { self.class.headings(body) }
  let(:slugs)    { headings.map { |_, t| self.class.slug(t) } }

  it "has no duplicate headings, which would make an anchor ambiguous" do
    dupes = slugs.tally.select { |_, n| n > 1 }.keys
    expect(dupes).to be_empty, "duplicate anchors: #{dupes.join(", ")}"
  end

  it "resolves every internal link" do
    linked = body.scan(/\]\(#([^)]+)\)/).flatten.uniq
    expect(linked - slugs).to be_empty,
      "these links point at headings that do not exist: #{(linked - slugs).join(", ")}"
  end

  # The contents block is generated from the headings. If it has drifted, it is
  # pointing somebody at the wrong section -- worse than having none.
  it "has a contents table matching its headings" do
    toc = body[/^## Contents\n(.*?)^---$/m, 1]
    expect(toc).not_to be_nil, "no ## Contents section"

    listed = toc.scan(/^\s*- \[(.+?)\]\(#/).flatten
    # Everything at ## and ### below the contents block itself.
    expected = self.class.headings(body[body.index("## Summary")..])
                   .select { |level, _| level.between?(2, 3) }
                   .map { |_, title| title }

    expect(listed).to eq(expected),
      "contents is stale:\n  missing: #{(expected - listed).join(", ")}\n" \
      "  extra:   #{(listed - expected).join(", ")}"
  end

  # Every task the engine registers should be findable by somebody reading the
  # docs rather than by somebody reading the rake file.
  it "documents every rake task the gem registers" do
    rake  = Pathname(AuditLog::GEM_ROOT).join("lib/audit_log/tasks/audit_log.rake").read
    tasks = rake.scan(/^\s{2}task (\w+)/).flatten.uniq

    undocumented = tasks.reject { |t| body.include?("audit_log:#{t}") }
    expect(undocumented).to be_empty,
      "these tasks exist but the README never mentions them: #{undocumented.join(", ")}"
  end
end
