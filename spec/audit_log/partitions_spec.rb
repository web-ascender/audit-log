# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditLog::Partitions do
  it "provisions the current month plus several ahead" do
    names = described_class.list
    (0..AuditLog.config.partition_months_ahead).each do |offset|
      month = (Time.now.utc.to_date.beginning_of_month >> offset)
      expect(names).to include(described_class.partition_name("audit_changes", month))
    end
  end

  it "is idempotent" do
    expect { described_class.ensure! }.not_to change { described_class.list.size }
  end

  it "keeps a default partition so a missed rotation cannot take writes down" do
    expect(described_class.list).to include("audit_changes_default", "audit_events_default")
  end

  it "reports nothing in the default partition when rotation is healthy" do
    expect(described_class.overflow_count.values).to all(eq(0))
  end

  it "routes a row into the partition for its month" do
    as_actor(create_user) { create_product }

    name = described_class.partition_name("audit_changes", Time.now.utc.to_date)
    count = ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{name}").to_i
    expect(count).to be_positive
  end

  # The UTC-midnight boundary is an invariant, not a preference: a boundary in a
  # DST-observing zone is 23 or 25 hours from its neighbour twice a year, so
  # adjacent months either overlap (CREATE fails) or leave a gap (rows land in
  # the default partition, which then blocks attaching the real one).
  describe "the UTC boundary invariant" do
    it "aligns every monthly bound to UTC midnight on the first of the month" do
      expect(described_class.misaligned_bounds).to eq([])
    end

    it "leaves no gap or overlap between consecutive months" do
      described_class::TABLES.each do |table|
        bounds = described_class.partition_bounds
          .select { |b| b[:name].start_with?("#{table}_") }
          .sort_by { |b| b[:lower] }

        bounds.each_cons(2) do |a, b|
          expect(b[:lower]).to eq(a[:upper]),
            "#{a[:name]} ends #{a[:upper].iso8601} but #{b[:name]} starts #{b[:lower].iso8601}"
        end
      end
    end

    # The regression guard for the real bug: create_month! used to interpolate a
    # bare date, which Postgres resolves against the session TimeZone at DDL
    # time. Run from psql (server default zone) it produced boundaries hours off
    # from the ones Rails produced. March is chosen because it straddles a DST
    # transition in the zone being set.
    it "is unaffected by the session TimeZone at DDL time" do
      conn = ActiveRecord::Base.connection
      original = conn.select_value("SHOW TimeZone")
      name = nil

      begin
        conn.execute("SET TIME ZONE 'America/Detroit'")
        name = described_class.create_month!("audit_changes", Date.new(2031, 3, 1))
        bound = described_class.partition_bounds.find { |b| b[:name] == name }

        expect(bound[:lower]).to eq(Time.utc(2031, 3, 1))
        expect(bound[:upper]).to eq(Time.utc(2031, 4, 1))
      ensure
        conn.execute("DROP TABLE IF EXISTS #{name}") if name
        conn.execute("SET TIME ZONE #{conn.quote(original)}")
      end
    end
  end
end
