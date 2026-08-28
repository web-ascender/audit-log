# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "generators/audit_log/trigger/trigger_generator"

RSpec.describe AuditLog::Generators::TriggerGenerator do
  def run_generator(args, dir:)
    output = StringIO.new
    orig, $stdout = $stdout, output
    described_class.start(args, destination_root: dir)
    output.string
  ensure
    $stdout = orig
  end

  around do |example|
    @dir = Dir.mktmpdir("audit_log_trigger")
    example.run
  ensure
    FileUtils.remove_entry(@dir)
  end

  def written(pattern) = File.read(Dir[File.join(@dir, "db/migrate/#{pattern}")].first)

  it "writes an attach migration, with detach as the down" do
    run_generator(%w[orders --model=Order], dir: @dir)
    body = written("*_audit_orders.rb")

    expect(body).to include('attach_audit_trigger :orders, model: "Order"')
    expect(body).to include("detach_audit_trigger :orders")
    expect(body).to include("ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]")
  end

  it "classifies the table name when --model is omitted" do
    run_generator(%w[line_items], dir: @dir)

    expect(written("*_audit_line_items.rb")).to include('model: "LineItem"')
  end

  it "renders --exclude as an exclusion list" do
    run_generator(%w[orders --exclude=internal_notes scratch], dir: @dir)

    expect(written("*_audit_orders.rb"))
      .to include('exclude: %w[internal_notes scratch]')
  end

  # detach-then-attach is the supported way to CHANGE a table's model or
  # exclusions, because attach is deliberately not idempotent -- the trigger name
  # is derived from the table alone, so a second attach collides with 42710 rather
  # than letting two triggers coexist and double-write under different exclusions.
  it "generates detach-then-attach under --replace" do
    run_generator(%w[orders --model=Order --exclude=notes --replace], dir: @dir)
    body = written("*_reattach_audit_trigger_to_orders.rb")

    expect(body.index("detach_audit_trigger :orders")).to be < body.index("attach_audit_trigger")
    expect(body).to include('exclude: %w[notes]')
    expect(body).to include("Not retroactive")
  end

  it "generates valid Ruby" do
    run_generator(%w[orders --model=Order --replace], dir: @dir)
    file = Dir[File.join(@dir, "db/migrate/*.rb")].first

    expect(system("ruby", "-c", file, out: File::NULL, err: File::NULL)).to be(true)
  end

  # The constraint the docs did not state until recently: the trigger assigns
  # `rec_id bigint := NEW.id`, so a uuid or non-`id` primary key fails on the first
  # WRITE rather than at migration time. Nothing can detect that from here -- the
  # generator does not have a database connection to the target table -- so saying
  # it is the only available protection.
  it "warns about the bigint id requirement, which it cannot check" do
    output = run_generator(%w[orders], dir: @dir)

    expect(output).to include("rec_id bigint := NEW.id")
    expect(output).to include("FAILS ON ITS FIRST WRITE")
  end

  it "warns that a plain attach collides when a trigger already exists" do
    expect(run_generator(%w[orders], dir: @dir)).to include("42710")
  end
end
