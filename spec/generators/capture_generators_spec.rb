# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "generators/audit_log/disable/disable_generator"
require "generators/audit_log/enable/enable_generator"

# DESIGN §25. Two generators, and the asymmetry between them is the design:
# `audit_log:disable` is the ordinary path and reads the CATALOG; `audit_log:enable`
# is the recovery path and reads the MARKER, because by then the catalog no longer
# holds what it needs.
#
# What these examples protect is the property the whole feature rests on: that
# what comes back is what was there. A migration that restores an approximation
# resumes capture under different arguments, and every row written afterwards is
# subtly wrong in a way nothing reports.
RSpec.describe "the capture generators" do
  # Thor's `start` rescues Thor::Error (which Rails::Generators::Error is) and
  # prints it instead of raising, so a refusal has to be exercised against the
  # step that raises it rather than through the command-line entry point.
  def build(klass, args = [], dir:)
    klass.new([], args, destination_root: dir)
  end

  def run_generator(klass, args = [], dir:)
    output = StringIO.new
    orig, $stdout = $stdout, output
    klass.start(args, destination_root: dir)
    output.string
  ensure
    $stdout = orig
  end

  around do |example|
    @dir = Dir.mktmpdir("audit_log_capture")
    example.run
  ensure
    FileUtils.remove_entry(@dir)
  end

  describe AuditLog::Generators::DisableGenerator do
    let(:migration) { File.read(Dir[File.join(@dir, "db/migrate/*_disable_audit_capture.rb")].first) }

    before { run_generator(described_class, ["--reason=cost of storage"], dir: @dir) }

    it "writes a migration that compiles" do
      expect { RubyVM::InstructionSequence.compile(migration) }.not_to raise_error
      expect(migration).to include("ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]")
    end

    # THE SNAPSHOT IS IN THE FILE, not looked up at run time. What comes back has
    # to be reviewable in a diff BEFORE it is run -- the same argument
    # `bypass_allowlist` makes for being a config file rather than a runtime grant.
    it "writes the model name for every audited table as a literal" do
      expect(migration).to include(%(table: "orders", model: "Order"))
      expect(migration).to include(%(table: "line_items", model: "LineItem"))
    end

    # OMITTED, never `dimensions: []`. The trigger function guards its extraction
    # on `TG_ARGV[2] IS NOT NULL`, so an empty list would attach a trigger
    # carrying an argument the original did not have.
    it "carries a declared facet list and omits the argument entirely otherwise" do
      orders = migration[/\{ table: "orders".*?\}/]
      users  = migration[/\{ table: "users".*?\}/]

      expect(orders).to include("dimensions: %w[customer_id created_by_id status]")
      expect(users).not_to include("dimensions")
    end

    # It looks redundant with config.default_excluded_columns and is not: passing
    # the MERGED list back reproduces the original argument byte for byte, and
    # still reproduces every exclusion the table had if a default is later removed
    # from the config.
    it "hands the merged exclusion list back whole" do
      expect(migration).to include("COMMON_EXCLUDED = %w[created_at updated_at")
      expect(migration).to include("password_digest")
    end

    it "records the reason, which is what the narration and the marker both carry" do
      expect(migration).to include(%(REASON = "cost of storage"))
    end

    # DESIGN §21.1. A table attached after the migration was generated is one
    # `down` cannot restore, so detaching it would be a silent permanent loss.
    it "refuses at run time if anything is still attached afterwards" do
      expect(migration).to include("AuditLog::Capture.attached.map")
      expect(migration).to include("still has an audit trigger")
    end

    it "bounds the lock wait rather than queueing behind a long reader" do
      expect(migration).to include("SET LOCAL lock_timeout")
    end

    it "narrates before detaching and clears the marker after re-attaching" do
      up, down = migration.split("def down")
      expect(up.index("Capture.disable!")).to be < up.index("detach_audit_trigger")
      expect(down.index("attach_audit_trigger")).to be < down.index("Capture.enable!")
    end

    it "explains the one genuinely lossy case, which is the one worth accepting knowingly" do
      expect(migration).to include("created AND deleted while capture is off")
    end

    # Never report success for work it did not do: a second disable would stamp a
    # new marker over the first and lose the original reason and date.
    it "refuses when capture is already disabled" do
      allow(AuditLog::Capture).to receive(:disabled?).and_return(true)
      allow(AuditLog::Capture).to receive(:status)
        .and_return("disabled_at" => "2026-01-01T00:00:00Z", "reason" => "earlier")

      expect { build(described_class, ["--reason=again"], dir: @dir).read_the_catalog }
        .to raise_error(Rails::Generators::Error, /already marked disabled.*earlier/m)
    end

    it "refuses when no trigger is attached, rather than writing a migration that does nothing" do
      allow(AuditLog::Capture).to receive(:attached).and_return([])

      expect { build(described_class, ["--reason=x"], dir: @dir).read_the_catalog }
        .to raise_error(Rails::Generators::Error, /nothing to disable/)
    end
  end

  describe AuditLog::Generators::EnableGenerator do
    let(:snapshot) do
      [{ table: "orders", model: "Order", excluded: %w[created_at updated_at], dimensions: %w[customer_id] },
       { table: "users",  model: "User",  excluded: %w[created_at updated_at], dimensions: [] }]
    end

    def stub_marker(triggers:)
      allow(AuditLog::Capture).to receive(:disabled?).and_return(true)
      allow(AuditLog::Capture).to receive(:status)
        .and_return("disabled_at" => "2026-01-01T00:00:00Z", "reason" => "a staging database")
      allow(AuditLog::Capture).to receive(:snapshot).and_return(triggers)
    end

    it "rebuilds the attach lines from the marker alone" do
      stub_marker(triggers: snapshot)
      run_generator(described_class, [], dir: @dir)
      migration = File.read(Dir[File.join(@dir, "db/migrate/*_enable_audit_capture.rb")].first)

      expect { RubyVM::InstructionSequence.compile(migration) }.not_to raise_error
      expect(migration).to include(%(table: "orders", model: "Order"))
      expect(migration).to include("dimensions: %w[customer_id]")
      expect(migration).to include("a staging database")
    end

    # It is the RECOVERY path, so it must not look like the ordinary one.
    it "points at db:migrate:down as the supported cycle" do
      stub_marker(triggers: snapshot)
      output = run_generator(described_class, [], dir: @dir)

      expect(output).to include("db:migrate:down")
    end

    it "refuses when capture is not disabled" do
      allow(AuditLog::Capture).to receive(:disabled?).and_return(false)

      expect { build(described_class, [], dir: @dir).read_the_marker }
        .to raise_error(Rails::Generators::Error, /not marked disabled/)
    end

    # AND WILL NOT GUESS. Reconstructing model names from table names is the
    # sniffing RecordLabel refuses to do, in a place where it would mislabel
    # `record_type` on every row written afterwards -- orders.created_by_id points
    # at User, and de-suffixing gives CreatedBy.
    it "refuses on a marker with no snapshot rather than inventing one" do
      stub_marker(triggers: [])

      expect { build(described_class, [], dir: @dir).read_the_marker }
        .to raise_error(Rails::Generators::Error, /no trigger snapshot.*will not guess/m)
    end
  end
end
