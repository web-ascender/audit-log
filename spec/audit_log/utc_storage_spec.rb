# frozen_string_literal: true

require "rails_helper"

# The audit tables must store absolute UTC instants no matter what the host app
# sets config.time_zone to. This is currently true STRUCTURALLY rather than by
# convention, and these examples exist to keep it that way -- the library is
# headed for a gem that will land in apps configured to Eastern, Central and UTC.
#
# Two properties do all the work:
#
#   1. occurred_at is `timestamptz`, which stores an absolute instant (8 bytes,
#      microseconds from 2000-01-01 UTC) and carries NO zone of its own. There is
#      no such thing as a timestamptz "in Eastern" -- the zone only ever affects
#      rendering.
#   2. occurred_at is filled by the column DEFAULT clock_timestamp(), inside
#      Postgres. Neither layer supplies it from Ruby: the trigger's INSERT omits
#      it (db/sql/audit_row_change.sql) and so does EventSubscriber#emit. So no
#      Ruby-side zone, and no Active Record type cast, is in the path at all.
#
# Break either property and config.time_zone starts silently shifting the
# historical record. The structural examples below are the ones that matter most,
# because they fail the moment someone reintroduces a Ruby-supplied timestamp or
# switches the column to `timestamp without time zone`.
RSpec.describe "UTC storage in the audit tables" do
  let(:conn) { ActiveRecord::Base.connection }

  describe "the column contract" do
    AuditLog::Partitions::TABLES.each do |table|
      it "#{table}.occurred_at is timestamptz, not a zoneless timestamp" do
        type = conn.select_value(<<~SQL)
          SELECT data_type FROM information_schema.columns
          WHERE table_name = '#{table}' AND column_name = 'occurred_at'
        SQL

        # `timestamp without time zone` would store whatever wall-clock string
        # the writer happened to produce, making the row's meaning depend on the
        # writer's zone. Note the BUSINESS tables use zoneless timestamps (the
        # Rails default); the audit tables deliberately do not.
        expect(type).to eq("timestamp with time zone")
      end

      it "#{table}.occurred_at is filled server-side by clock_timestamp()" do
        default = conn.select_value(<<~SQL)
          SELECT column_default FROM information_schema.columns
          WHERE table_name = '#{table}' AND column_name = 'occurred_at'
        SQL

        expect(default).to eq("clock_timestamp()")
      end
    end

    it "never supplies occurred_at from Ruby in either layer" do
      # The guard for the failure mode the column contract cannot catch: a
      # timestamptz column still round-trips correctly, but routing the value
      # through Ruby puts Active Record's type casting and the host app's zone
      # config into a path that currently has neither.
      gem_file = ->(path) { File.read(File.join(AuditLog::GEM_ROOT, path)) }

      trigger = gem_file.call("db/sql/audit_row_change.sql")
      insert  = trigger[/INSERT INTO audit_changes\s*\((.+?)\)/m, 1]

      expect(insert).not_to include("occurred_at")
      expect(gem_file.call("lib/audit_log/event_subscriber.rb"))
        .not_to match(/occurred_at:/)
    end
  end

  describe "storage is independent of config.time_zone" do
    # Generous tolerance on purpose: this is looking for a TIMEZONE-sized error
    # (hours), not clock precision. A tight bound would only add flake.
    TOLERANCE = 5.minutes

    ["UTC", "Eastern Time (US & Canada)", "Central Time (US & Canada)", "Asia/Kolkata"].each do |zone|
      it "stores the true instant when config.time_zone is #{zone}" do
        Time.use_zone(zone) do
          expected = Time.now.utc
          product  = as_actor(create_user) { create_product }

          stored = AuditLog::Change
            .where(record_type: "Product", record_id: product.id)
            .pick(:occurred_at)

          expect(stored).to be_within(TOLERANCE).of(expected)

          # The assertion that actually distinguishes right from wrong: had the
          # zone leaked in, stored would be off by exactly the zone's offset.
          offset = Time.zone.now.utc_offset
          next if offset.zero?
          expect((stored - expected).abs).to be < offset.abs
        end
      end
    end

    it "stores the true instant even when the DB session TimeZone is not UTC" do
      # A host app can set this via `variables: { timezone: ... }` in
      # database.yml. It must not matter, because clock_timestamp() returns an
      # absolute instant regardless of how the session would render it.
      original = conn.select_value("SHOW TimeZone")

      begin
        conn.execute("SET TIME ZONE 'America/Detroit'")
        expected = Time.now.utc
        product  = as_actor(create_user) { create_product }

        stored = AuditLog::Change
          .where(record_type: "Product", record_id: product.id)
          .pick(:occurred_at)

        expect(stored.utc).to be_within(TOLERANCE).of(expected)
      ensure
        conn.execute("SET TIME ZONE #{conn.quote(original)}")
      end
    end
  end
end
