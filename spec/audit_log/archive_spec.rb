# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "csv"

# ROLLOUT Q8. The manifest is the whole point: dropping a partition must be
# impossible unless a verified export of it exists. Detach, export, verify, drop
# -- never drop-then-hope.
RSpec.describe AuditLog::Archive do
  let(:conn) { ActiveRecord::Base.connection }
  around { |ex| Dir.mktmpdir { |dir| @dir = dir; ex.run } }
  attr_reader :dir

  def insert_change(at:, record_id: 1)
    conn.execute(<<~SQL)
      INSERT INTO audit_changes
        (occurred_at, record_type, record_id, operation, diff, changed_columns)
      VALUES ('#{at} 12:00:00+00', 'Order', #{record_id}, 'U',
              '{"status":["a","b"]}', '{status}')
    SQL
  end

  # A real retired partition: created, filled, detached and renamed by retire!.
  def retire_a_partition(rows: 3)
    AuditLog::Partitions.create_month!("audit_changes", Date.new(2015, 1, 1))
    rows.times { |i| insert_change(at: "2015-01-#{10 + i}", record_id: i + 1) }
    AuditLog::Partitions.retire!(retention: 7.years)
    "audit_changes_retired_2015_01"
  end

  describe ".export!" do
    it "streams the partition to a gzipped CSV with a manifest" do
      name = retire_a_partition(rows: 3)

      manifest = described_class.export!(name, dir: dir)

      expect(manifest[:rows]).to eq(3)
      expect(manifest[:partition]).to eq(name)
      expect(File).to exist(described_class.data_path(dir, name))
      expect(File).to exist(described_class.manifest_path(dir, name))
    end

    it "writes every row and every column, readable without this library" do
      name = retire_a_partition(rows: 3)
      described_class.export!(name, dir: dir)

      csv = Zlib::GzipReader.open(described_class.data_path(dir, name)) { |gz| CSV.parse(gz.read, headers: true) }

      expect(csv.size).to eq(3)
      expect(csv.headers).to include("occurred_at", "record_type", "diff", "actor_label")
      expect(csv.map { |r| r["record_id"] }).to match_array(%w[1 2 3])
    end

    # COPY ... TO STDOUT is the only export path that needs no server
    # filesystem, no superuser and no extension -- which is what makes it work
    # unchanged on RDS, Cloud SQL and Azure. See the comment in archive.rb.
    it "needs no server-side filesystem access" do
      name = retire_a_partition(rows: 1)
      expect { described_class.export!(name, dir: dir) }.not_to raise_error
      expect(conn.select_value("SELECT current_setting('is_superuser')")).to eq("off").or eq("on")
    end
  end

  describe ".verify!" do
    it "accepts an intact export" do
      name = retire_a_partition(rows: 3)
      described_class.export!(name, dir: dir)

      expect { described_class.verify!(name, dir: dir) }.not_to raise_error
    end

    it "rejects a corrupted file" do
      name = retire_a_partition(rows: 3)
      described_class.export!(name, dir: dir)
      File.write(described_class.data_path(dir, name),
                 Zlib::Deflate.deflate("not the export"), mode: "wb")

      # VerificationError, not Zlib::GzipFile::Error: an unreadable export has to
      # be a reported refusal, or one corrupt file aborts drop_exported! partway
      # and the partitions after it are silently never looked at.
      expect { described_class.verify!(name, dir: dir) }
        .to raise_error(AuditLog::Archive::VerificationError, /unreadable/)
    end

    # Catches the export that was taken against a different partition, or before
    # more rows arrived -- which a checksum alone cannot see.
    it "rejects an export whose row count disagrees with the table" do
      name = retire_a_partition(rows: 3)
      described_class.export!(name, dir: dir)
      conn.execute("INSERT INTO #{name} (occurred_at, record_type, record_id, operation, diff, changed_columns)
                    VALUES ('2015-01-20 12:00:00+00', 'Order', 99, 'U', '{}', '{}')")

      expect { described_class.verify!(name, dir: dir) }
        .to raise_error(AuditLog::Archive::VerificationError, /export holds 3 row\(s\) but the table holds 4/)
    end

    it "refuses when there is no manifest at all" do
      name = retire_a_partition(rows: 1)

      expect { described_class.verify!(name, dir: dir) }
        .to raise_error(AuditLog::Archive::VerificationError, /no manifest/)
    end
  end

  describe ".drop_exported!" do
    it "drops a partition whose export verifies, and reclaims the space" do
      name = retire_a_partition(rows: 3)
      described_class.export!(name, dir: dir)

      result = described_class.drop_exported!(dir: dir)

      expect(result).to contain_exactly(hash_including(name: name, dropped: true))
      expect(conn.select_value("SELECT to_regclass('public.#{name}')::text")).to be_nil
    end

    # The single most important assertion in this file.
    it "REFUSES to drop a partition with no export, and says why" do
      name = retire_a_partition(rows: 3)

      result = described_class.drop_exported!(dir: dir)

      expect(result).to contain_exactly(hash_including(name: name, dropped: false))
      expect(result.first[:error]).to match(/no manifest/)
      expect(conn.select_value("SELECT count(*) FROM #{name}").to_i).to eq(3)
    end

    it "REFUSES to drop a partition whose export is corrupt" do
      name = retire_a_partition(rows: 3)
      described_class.export!(name, dir: dir)
      File.write(described_class.data_path(dir, name), Zlib::Deflate.deflate("junk"), mode: "wb")

      result = described_class.drop_exported!(dir: dir)

      expect(result.first[:dropped]).to be(false)
      expect(conn.select_value("SELECT count(*) FROM #{name}").to_i).to eq(3)
    end
  end

  describe ".export_retired!" do
    # It used to skip a partition when two files existed in `dir`. That is not
    # evidence of anything -- the file can be truncated, corrupt, zero-length, a
    # stale export of an earlier state, or on a container filesystem that ceased
    # to exist. Skipping on that basis means the ONE case where a re-export
    # matters is the case it skips, while reporting success.
    it "exports every retired partition on every run, not just new ones" do
      name = retire_a_partition(rows: 2)

      expect(described_class.export_retired!(dir: dir).map { |m| m[:partition] }).to eq([name])
      expect(described_class.export_retired!(dir: dir).map { |m| m[:partition] }).to eq([name])
    end

    # The reason re-exporting is safe rather than merely wasteful: the previous
    # archive survives until the new one is complete AND verified. Opening the
    # destination directly would truncate a good export at byte zero and then
    # stream a replacement.
    it "writes through a temp file, so an interrupted run cannot destroy a good export" do
      name = retire_a_partition(rows: 2)
      described_class.export_retired!(dir: dir)
      good = File.binread(described_class.data_path(dir, name))

      allow(described_class).to receive(:verify!).and_raise(AuditLog::Archive::VerificationError, "boom")
      expect { described_class.export!(name, dir: dir) }.to raise_error(AuditLog::Archive::VerificationError)

      expect(File.binread(described_class.data_path(dir, name))).to eq(good)
      expect(Dir.glob("#{dir}/*.tmp")).to be_empty
    end

    # Verification used to happen only as a side effect of dropping, so an
    # operator who exported monthly and never dropped had never once checked
    # that their archives were readable.
    it "verifies each export as it writes it" do
      name = retire_a_partition(rows: 2)
      expect(described_class).to receive(:verify!).with(name, hash_including(dir: dir)).and_call_original

      described_class.export_retired!(dir: dir)
    end

    it "reports a failure and carries on rather than aborting the run" do
      retire_a_partition(rows: 2)
      allow(described_class).to receive(:export!).and_raise(AuditLog::Archive::VerificationError, "boom")

      results = described_class.export_retired!(dir: dir)
      expect(results.first).to include(ok: false)
      expect(results.first[:error]).to match(/boom/)
    end
  end
end
