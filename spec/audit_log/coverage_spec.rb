# frozen_string_literal: true

require "rails_helper"
require "audit_log/rspec"

# The forcing function, exercised here exactly as a host application exercises it
# -- through the shared example the gem ships. If this file grows beyond these
# three lines, the shared example is missing something a host app needs.
RSpec.describe "audit trigger coverage" do
  it_behaves_like "an app with complete audit coverage"
end

# And the object underneath it, which the rake task shares.
RSpec.describe AuditLog::Coverage do
  subject(:coverage) { described_class.new }

  it "reads pg_trigger rather than the migration history" do
    expect(coverage.audited_tables)
      .to include("orders", "line_items", "products", "customers", "shipments", "users")
  end

  it "never counts a partition as a candidate for auditing" do
    expect(coverage.partition_tables).to include(a_string_matching(/\Aaudit_changes_\d{4}_\d{2}\z/))
    expect(coverage.missing).to be_empty
  end

  it "reports a table with no trigger and no exemption" do
    ActiveRecord::Base.connection.create_table(:widgets) { |t| t.string :name }

    expect(coverage.missing).to include("widgets")
    expect(coverage).not_to be_ok
    # The count LEADS the list. A forty-table wall scrolls, and a CI log showing
    # only its tail reads as a handful of findings.
    expect(coverage.report).to include("1 untracked table: widgets").and include("attach_audit_trigger")
  ensure
    ActiveRecord::Base.connection.drop_table(:widgets, if_exists: true)
  end

  # Catalog order is creation order, which nobody scanning the list is using.
  it "reports untracked tables alphabetically" do
    %i[zebras aardvarks].each { |t| ActiveRecord::Base.connection.create_table(t) { |x| x.string :name } }

    expect(coverage.missing).to eq(%w[aardvarks zebras])
    expect(coverage.report).to include("2 untracked tables: aardvarks, zebras")
  ensure
    %i[zebras aardvarks].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  it "reports an exemption whose table has been dropped" do
    allow(AuditLog.config).to receive(:unaudited_tables)
      .and_return(AuditLog.config.unaudited_tables.merge("long_gone" => "was removed in 2019"))

    expect(coverage.stale_exemptions).to eq(%w[long_gone])
    expect(coverage).not_to be_ok
  end

  it "reports an exemption with no written reason" do
    allow(AuditLog.config).to receive(:unaudited_tables)
      .and_return(AuditLog.config.unaudited_tables.merge("users" => "  "))

    expect(coverage.unreasoned_exemptions).to eq(%w[users])
    expect(coverage).not_to be_ok
  end
end
