# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "generators/audit_log/dimensions/dimensions_generator"

# The RETROFIT path for DESIGN §23. A new install never runs this -- the column
# and the index ship with audit_tables.sql -- so everything here is about an
# established deployment with years of audit rows already in place, where the
# obvious spelling is a write-path outage.
RSpec.describe AuditLog::Generators::DimensionsGenerator do
  def run_generator(dir:)
    output = StringIO.new
    orig, $stdout = $stdout, output
    described_class.start([], destination_root: dir)
    output.string
  ensure
    $stdout = orig
  end

  around do |example|
    @dir = Dir.mktmpdir("audit_log_dimensions")
    example.run
  ensure
    FileUtils.remove_entry(@dir)
  end

  let(:migration) { File.read(Dir[File.join(@dir, "db/migrate/*_add_audit_log_dimensions.rb")].first) }

  before { run_generator(dir: @dir) }

  it "writes a migration that compiles" do
    expect { RubyVM::InstructionSequence.compile(migration) }.not_to raise_error
    expect(migration).to include("ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]")
  end

  # MANDATORY, and the reason is not stylistic: CREATE INDEX CONCURRENTLY cannot
  # run inside a transaction, and CONCURRENTLY is the whole point -- add_index on
  # a partitioned parent builds across every partition under a lock that blocks
  # every audited write in the application.
  it "disables the DDL transaction" do
    expect(migration).to include("disable_ddl_transaction!")
  end

  it "adds the column nullable with no default" do
    expect(migration).to include("add_column table, :dimensions, :jsonb")
    expect(migration).not_to include("null: false")
    expect(migration).not_to include("default:")
  end

  # THE SILENT-FAILURE HALF. The pre-feature trigger function does not read
  # TG_ARGV[2], so declaring `dimensions:` against it records nothing, forever,
  # with the column and index both in place and no error anywhere.
  it "re-installs the trigger function, without which facets record nothing" do
    expect(migration).to include("AuditLog::Schema.install_function!")
  end

  it "builds the index through the per-partition helper rather than add_index" do
    expect(migration).to include("AuditLog::DimensionIndex.install!")
    expect(migration).not_to match(/add_index.*dimensions/)
  end

  # DESIGN §21.1: never report success for work it did not do. Disabling the DDL
  # transaction means a failure leaves partial state by construction, so the
  # migration has to verify rather than assume -- and it verifies against the
  # CATALOG's own completeness flag, not against its own arithmetic.
  it "asserts completeness from the catalog instead of counting partitions" do
    expect(migration).to include("AuditLog::DimensionIndex.complete?")
    expect(migration).to include("raise")
    expect(migration).not_to include(".count")
  end

  it "is re-runnable: it skips a column that already exists" do
    expect(migration).to include("next if column_exists?(table, :dimensions)")
  end

  it "says the down discards recorded facets rather than implying it is free" do
    expect(migration).to match(/DISCARDS/)
  end

  # A generator whose failure is invisible has to say what it needs. Two things
  # here are genuinely surprising and both are printed: that it is slow on a long
  # horizon, and that it records NOTHING until something declares a facet.
  it "tells the operator what the migration will and will not do" do
    output = run_generator(dir: Dir.mktmpdir("audit_log_dimensions_out"))

    expect(output).to include("CONCURRENTLY")
    expect(output).to include("SAFE TO RE-RUN")
    expect(output).to include("Nothing is recorded until a table or an action declares a facet")
    expect(output).to include("NOT retroactive")
  end
end
