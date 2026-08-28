# frozen_string_literal: true

require "rails_helper"

# The forcing function for the whole design.
#
# Layer 1 is opt-in per table -- one attach_audit_trigger line in the migration --
# which is deliberate: auditing every table automatically would sweep in queue,
# cache and session tables whose churn would bury real findings. The risk of
# opt-in is that a table gets added and nobody decides. This spec makes that
# decision mandatory: a new table either gets a trigger or gets a written reason,
# or the build breaks.
RSpec.describe "audit trigger coverage" do
  let(:connection) { ApplicationRecord.connection }

  # Partitions inherit their parent's triggers and cannot be attached
  # independently, so they are not candidates for auditing. Excluding them here
  # rather than listing each one in unaudited_tables keeps the exemption list
  # about DECISIONS instead of about partition rotation.
  def partition_tables
    connection.select_values(<<~SQL)
      SELECT c.relname
      FROM   pg_class c
      JOIN   pg_inherits i ON i.inhrelid = c.oid
    SQL
  end

  def audited_tables
    connection.select_values(<<~SQL)
      SELECT c.relname
      FROM   pg_trigger t
      JOIN   pg_class c ON c.oid = t.tgrelid
      WHERE  NOT t.tgisinternal
        AND  t.tgname LIKE '%\\_audit'
    SQL
  end

  it "audits every table that has not been explicitly exempted" do
    # ApplicationRecord, not ActiveRecord::Base: with Solid Queue in its own
    # database we only want the primary connection's tables here.
    exempt  = AuditLog.config.unaudited_tables.keys
    missing = connection.tables - audited_tables - exempt - partition_tables

    expect(missing).to be_empty,
      "Untracked tables: #{missing.join(', ')}. " \
      "Add attach_audit_trigger to the migration, or add the table to " \
      "AuditLog.config.unaudited_tables with a reason."
  end

  it "does not exempt a table that no longer exists" do
    stale = AuditLog.config.unaudited_tables.keys - connection.tables
    expect(stale).to be_empty,
      "These tables are exempted but do not exist: #{stale.join(', ')}"
  end

  it "records a reason for every exemption" do
    blank = AuditLog.config.unaudited_tables.reject { |_, reason| reason.present? }
    expect(blank).to be_empty
  end

  it "does not audit the audit tables themselves" do
    expect(audited_tables).not_to include("audit_changes", "audit_events")
  end
end
