# frozen_string_literal: true

require "rails_helper"
require "generators/audit_log/views/css/css_generator"
require "fileutils"
require "tmpdir"

# The stylesheet ships COMMENTED OUT, which makes two properties load-bearing and
# neither is visible by reading the file casually: that nothing in it is live as
# generated, and that enabling it the documented way yields CSS rather than
# wreckage. A `/* ... */` written inside a section would silently break both.
RSpec.describe AuditLog::Generators::Views::CssGenerator do
  let(:app) { Dir.mktmpdir("audit-css") }
  let(:target) { File.join(app, "app/assets/stylesheets/audit_log.css") }

  before { FileUtils.mkdir_p(File.join(app, "app/assets/stylesheets")) }
  after  { FileUtils.remove_entry(app) }

  # Same capture as install_generator_spec: the generator's report is part of
  # what it does, and a spec suite is not where it should be read.
  def generate(argv = [])
    orig, $stdout = $stdout, StringIO.new
    described_class.start(argv, destination_root: app, behavior: :invoke,
                                shell: Thor::Shell::Basic.new)
    File.read(target)
  ensure
    $stdout = orig
  end

  # Delete every line that opens or closes a block comment -- what the file's own
  # header says to do, and what the generator prints. Spelled here rather than
  # shelling out to sed so the assertion is about the FILE, not about which sed.
  def enable(css)
    css.lines.reject { |l| l.start_with?("/*") || l.chomp == "*/" }.join
  end

  # Strip comments the way a browser does, and see what is left.
  def live_rules(css) = css.gsub(%r{/\*.*?\*/}m, "").strip

  it "writes a stylesheet that is inert as generated" do
    expect(live_rules(generate)).to be_empty
  end

  it "leaves real CSS behind when enabled the documented way" do
    enabled = enable(generate)

    expect(live_rules(enabled)).not_to be_empty
    expect(enabled.count("{")).to eq(enabled.count("}"))
    expect(enabled).not_to include("/*"), "a nested comment survived enabling"
    expect(enabled).not_to include("*/")
  end

  # Every rule scoped, because the screens use generic class names -- .card,
  # .note, .new, .old -- and an unscoped stylesheet would restyle the host's own
  # application the moment somebody uncommented it. That is the whole reason the
  # engine's screens are wrapped in .audit-log.
  it "scopes every selector under .audit-log" do
    # Everything between one brace and the next `{` is a selector group --
    # including inside @media, where the rules are indented.
    selectors = enable(generate).scan(/([^{}]+)\{/m).flatten
      .flat_map { |group| group.split(",") }
      .map(&:strip).reject { |s| s.empty? || s.start_with?("@") }

    expect(selectors).not_to be_empty
    unscoped = selectors.reject { |s| s.start_with?(".audit-log") }
    expect(unscoped).to be_empty, "these would leak into the host app: #{unscoped.join(", ")}"
  end

  # The classes an auditor reads MEANING from, as opposed to layout. A screen
  # that renders one of these with no rule behind it is the failure this file
  # exists to prevent: a removed value that does not look removed.
  it "styles every class that carries meaning rather than layout" do
    css = generate

    %w[assoc-id assoc-missing assoc-failed nil-value redaction-note
       op-insert op-update op-delete source-job source-console
       kind-narrative redacted touched-fields empty warn].each do |klass|
      expect(css).to include(".#{klass}"), "nothing styles .#{klass}"
    end
  end

  # The wrapper the whole stylesheet hangs off has to exist on the screens
  # themselves, or every rule above is scoped to nothing. This is the one
  # assertion that reaches back into the engine.
  it "hangs off a wrapper the engine's screens actually render" do
    templates = Pathname.glob(Pathname.new(AuditLog::GEM_ROOT).join("app/views/**/*.html.erb"))
      .reject { |p| p.basename.to_s.start_with?("_") }

    expect(templates.size).to be >= 11
    expect(templates.reject { |p| p.read.include?('<div class="audit-log">') }).to be_empty
  end

  it "leaves an edited stylesheet alone on a second run" do
    generate
    File.write(target, "/* mine */\n.audit-log { color: rebeccapurple; }\n")

    expect(generate).to eq("/* mine */\n.audit-log { color: rebeccapurple; }\n")
  end

  it "names the mount path it was given, so the header is not a guess" do
    expect(generate(["--mount-path=/compliance/audit"])).to include("/compliance/audit")
  end
end
