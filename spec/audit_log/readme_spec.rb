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
#
# `llms.txt` is guarded from here too, and from here rather than from its own file
# because it links into README.md by anchor and the GitHub slug rules below are the
# subtle part. Two copies of those rules would drift faster than the documents they
# check.
RSpec.describe "README.md" do
  README = Pathname(AuditLog::GEM_ROOT).join("README.md")

  # GitHub's own slug rules: strip formatting, downcase, drop punctuation, then
  # hyphenate spaces ONE FOR ONE. Collapsing runs of whitespace here instead
  # would be wrong in exactly the case that bites -- "Retention -- schedulable"
  # loses the dash and keeps both spaces, so GitHub's anchor has a double hyphen
  # and a contents link built on a collapsed slug is dead on arrival while this
  # spec stays green.
  def self.slug(text)
    text = text.gsub(/`([^`]*)`/, '\1').gsub(/\*\*?([^*]*)\*\*?/, '\1')
    text.downcase.gsub(/[^\w\s-]/, "").strip.tr(" ", "-")
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

  # A README section can be DRAFTED in DESIGN.md before the feature it documents
  # exists: the README must not describe what an adopter cannot use, and wording
  # that took a pass to get right is worth keeping rather than re-deriving. That
  # draft is STAGING, never a second home -- two copies of the same user
  # documentation drift, which is the failure the generator templates exist to
  # prevent, and it is how DESIGN.md would slowly become a second README.
  #
  # So the moment README.md carries the heading a draft names, the draft has to
  # go. This is that deletion trigger. Without it the duplicate survives silently,
  # which is exactly the kind of rot the contents-table examples above exist for.
  it "stages no README draft for a section README.md already carries" do
    design = Pathname(AuditLog::GEM_ROOT).join("DESIGN.md").read
    staged = design.scan(/<!-- README-DRAFT heading="([^"]+)" -->/).flatten
    landed = staged.select { |h| headings.any? { |_, text| text == h } }

    expect(landed).to be_empty,
      "DESIGN.md still stages a README draft for #{landed.map(&:inspect).join(", ")}, which " \
      "README.md now carries. Move any remaining wording across and delete the staged block " \
      "from DESIGN.md -- two copies of the same user documentation drift."
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

  # Same forcing function as the rake tasks below. A config attribute the README
  # never mentions is one an adopting app cannot discover without reading
  # configuration.rb -- and every one of these is a coupling point somebody may
  # need to set.
  it "documents every configuration attribute" do
    config = Pathname(AuditLog::GEM_ROOT).join("lib/audit_log/configuration.rb").read
    attrs  = config.scan(/attr_accessor :(\w+)/).flatten.uniq

    undocumented = attrs.reject { |a| body.include?("`#{a}`") }
    expect(undocumented).to be_empty,
      "these config attributes exist but the README never names them: #{undocumented.join(", ")}"
  end

  # The README hands its depth to DESIGN.md by section number (CLAUDE.md, "What
  # belongs in which document"), which only works while those numbers exist. A
  # "measurements are in DESIGN §11.2b" that points at nothing is worse than the
  # paragraph it replaced -- the reader was told there is more and cannot find it,
  # and nothing else in either file would notice. DESIGN gets renumbered; this is
  # what makes that safe.
  it "resolves every DESIGN section it points at" do
    design = Pathname(AuditLog::GEM_ROOT).join("DESIGN.md").read
    # `## 7. Layer 2 ...` and `### 11.2b The host-facing timeline ...` both.
    sections = design.scan(/^\#{2,4} (\d+(?:\.\d+)?[a-z]?)\.? /).flatten.to_set
    referenced = body.scan(/§\s*(\d+(?:\.\d+)?[a-z]?)/).flatten.uniq

    expect(referenced).not_to be_empty, "the README cites no DESIGN sections at all"
    dangling = referenced.reject { |r| sections.include?(r) }
    expect(dangling).to be_empty,
      "the README points at DESIGN sections that do not exist: #{dangling.map { |d| "§#{d}" }.join(", ")}"
  end

  # llms.txt is the entry point an AGENT reaches these documents through, and it is
  # the one document nobody looks at while working -- so every way it can rot is
  # invisible. It routes by anchor into a README that gets rewritten, it cites
  # DESIGN sections that get renumbered, and it is useless unless it is packaged.
  describe "llms.txt" do
    let(:llms) { Pathname(AuditLog::GEM_ROOT).join("llms.txt").read }

    def packaged
      Dir.chdir(AuditLog::GEM_ROOT) { Gem::Specification.load("audit_log.gemspec").files }
    end

    def linked_files
      llms.scan(/\]\(([^)#]+)(?:#[^)]*)?\)/).flatten.uniq.grep_v(%r{\Ahttps?://})
    end

    it "resolves every README section it routes to" do
      linked = llms.scan(/\]\(README\.md#([^)]+)\)/).flatten.uniq
      expect(linked).not_to be_empty, "llms.txt routes to no README section at all"

      expect(linked - slugs).to be_empty,
        "llms.txt points at README headings that do not exist: #{(linked - slugs).join(", ")}"
    end

    it "links no file the gem does not have" do
      missing = linked_files.reject { |f| Pathname(AuditLog::GEM_ROOT).join(f).exist? }

      expect(missing).to be_empty, "llms.txt links files that do not exist: #{missing.join(", ")}"
    end

    it "resolves every DESIGN section it cites" do
      design   = Pathname(AuditLog::GEM_ROOT).join("DESIGN.md").read
      sections = design.scan(/^\#{2,4} (\d+(?:\.\d+)?[a-z]?)\.? /).flatten.to_set
      dangling = llms.scan(/§\s*(\d+(?:\.\d+)?[a-z]?)/).flatten.uniq.reject { |r| sections.include?(r) }

      expect(dangling).to be_empty,
        "llms.txt points at DESIGN sections that do not exist: #{dangling.map { |d| "§#{d}" }.join(", ")}"
    end

    # The whole mechanism is "an agent resolves `bundle info audit_log --path` and
    # reads what is there". A document left out of spec.files is present in the
    # repository and absent from every app that installs the gem.
    it "is packaged, along with everything it links to" do
      expect(packaged).to include("llms.txt")
      expect(linked_files - packaged).to be_empty,
        "llms.txt links documents that are not in spec.files: #{(linked_files - packaged).join(", ")}"
    end

    # The mirror image, and a decision rather than an oversight (DESIGN §22, §24):
    # CLAUDE.md is written for somebody CHANGING the gem, so shipping it to every
    # host app would hand an agent the rules for the wrong job.
    it "does not package CLAUDE.md" do
      expect(packaged).not_to include("CLAUDE.md")
    end
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
