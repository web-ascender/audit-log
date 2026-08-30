# frozen_string_literal: true

require "digest"
require "json"
require "zlib"

module AuditLog
  # Export a retired partition to a file, verify it, then drop it. ROLLOUT Q8.
  #
  # WHY `COPY ... TO STDOUT` AND NOT ANYTHING ELSE
  #
  # The constraint is managed Postgres -- RDS, Aurora, Cloud SQL, Azure Flexible.
  # Every other option fails on at least one of them:
  #
  #   * `COPY ... TO '/path'` writes on the SERVER and needs superuser plus a
  #     filesystem you do not have.
  #   * `COPY ... TO PROGRAM` needs superuser. Same.
  #   * `aws_s3.query_export_to_s3` is an RDS-only extension, and ties the
  #     library to one cloud.
  #   * Cloud SQL's export API is GCP-only and operates on whole tables via
  #     gcloud, outside the application entirely.
  #   * `pg_dump -t` works, but needs the binary present, a second set of
  #     credentials, and a client version matching the server.
  #
  # `COPY ... TO STDOUT` streams through the connection the application already
  # has. No server filesystem, no superuser, no extension, no extra credentials,
  # identical on every provider -- including plain self-hosted Postgres.
  #
  # WHERE THE FILE GOES IS NOT THIS LIBRARY'S BUSINESS. It writes a local file and
  # stops. Uploading it to S3, GCS or a tape robot is a deployment decision, and
  # baking one in is what would make this un-copyable.
  #
  # The manifest is the point of the whole exercise: `drop!` refuses to drop a
  # partition that has no verified export beside it. Detach, export, verify,
  # drop -- never drop-then-hope.
  module Archive
    FORMAT_VERSION = 1

    class VerificationError < Error; end

    class << self
      # Stream one retired partition to <dir>/<name>.csv.gz plus a manifest.
      #
      # Gzipped because audit rows are highly repetitive text -- the same actor
      # labels, record types and column names on every row -- and because the
      # thing is write-once, read-almost-never.
      # WRITTEN TO A TEMP FILE AND RENAMED INTO PLACE, which is load-bearing now
      # that `export_retired!` re-exports unconditionally. Opening the
      # destination with "wb" truncates it at byte zero, so a run interrupted
      # mid-stream -- a full disk, a dropped connection, a killed container --
      # would have destroyed a good archive to produce a partial one. Rename is
      # atomic within a filesystem, so the previous export survives until the new
      # one is complete AND verified.
      def export!(name, dir:, connection: ActiveRecord::Base.connection)
        FileUtils.mkdir_p(dir)
        raw    = connection.raw_connection
        digest = Digest::SHA256.new
        rows   = 0
        tmp    = "#{data_path(dir, name)}.tmp"

        File.open(tmp, "wb") do |file|
          gz = Zlib::GzipWriter.new(file)
          begin
            raw.copy_data(<<~SQL) do
              COPY (SELECT * FROM #{connection.quote_table_name(name)})
              TO STDOUT WITH (FORMAT csv, HEADER, ENCODING 'UTF8')
            SQL
              while (chunk = raw.get_copy_data)
                digest << chunk
                gz.write(chunk)
                rows += chunk.count("\n")
              end
            end
          ensure
            # finish, not close: it writes the gzip trailer and hands back the
            # underlying IO still open, so the fsync below has something to sync.
            # close would take `file` down with it.
            gz.finish
          end
          file.fsync
        end

        manifest = {
          format_version: FORMAT_VERSION,
          partition:      name,
          rows:           rows - 1, # the HEADER line
          sha256:         digest.hexdigest,
          bytes:          File.size(tmp),
          exported_at:    Time.now.utc.iso8601,
          columns:        connection.columns(name).map(&:name)
        }

        File.rename(tmp, data_path(dir, name))
        File.write(manifest_path(dir, name), JSON.pretty_generate(manifest))

        # VERIFIED HERE, not only at drop time. Until this existed, verification
        # happened solely as a side effect of dropping -- so an operator who
        # exported monthly and never dropped had never once checked that their
        # archives were readable, and would find out the first time they needed
        # one. Re-reads from the page cache, so it costs close to nothing.
        verify!(name, dir: dir, connection: connection)
        manifest
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      # Re-read the file and check it against its manifest AND against the live
      # table. Both halves matter: the checksum catches a truncated or corrupted
      # write, and the row count catches an export taken against a different
      # partition than the one about to be dropped.
      def verify!(name, dir:, connection: ActiveRecord::Base.connection)
        manifest = read_manifest(dir, name) or
          raise VerificationError, "no manifest for #{name} in #{dir}"

        digest = Digest::SHA256.new
        begin
          Zlib::GzipReader.open(data_path(dir, name)) { |gz| digest << gz.read(65_536) while !gz.eof? }
        rescue Zlib::Error, SystemCallError, IOError => e
          # Re-raised as VerificationError so an unreadable file is a REPORTED
          # refusal rather than an exception that aborts drop_exported! partway
          # through -- which would leave later partitions silently unprocessed.
          raise VerificationError, "#{name}: export is unreadable (#{e.class}: #{e.message})"
        end

        unless digest.hexdigest == manifest["sha256"]
          raise VerificationError, "#{name}: checksum mismatch; the export is corrupt or truncated"
        end

        live = connection.select_value("SELECT count(*) FROM #{connection.quote_table_name(name)}").to_i
        unless live == manifest["rows"]
          raise VerificationError,
                "#{name}: export holds #{manifest["rows"]} row(s) but the table holds #{live}"
        end

        manifest
      end

      # EVERY retired partition, EVERY run. It does not skip what it exported
      # before, and that is deliberate rather than wasteful.
      #
      # The old version skipped a partition when two files existed in `dir`. That
      # is not evidence of anything: the file may be truncated, corrupt,
      # zero-length, a stale export of an earlier state, or sitting on a
      # container filesystem that ceased to exist minutes later. Skipping on that
      # basis means THE ONE CASE WHERE A RE-EXPORT MATTERS -- the archive went
      # bad -- is precisely the case it skips, while reporting success.
      #
      # Nor can this library know whether a file reached durable storage. A path
      # in `dir` says nothing about S3. So it stops pretending to track that, and
      # does the thing its name says instead: export the retired partitions.
      #
      # A failure on one is reported and the rest continue -- the same rule the
      # drop path follows, so one bad partition cannot leave later ones silently
      # unprocessed.
      def export_retired!(dir:, connection: ActiveRecord::Base.connection)
        AuditLog::Partitions.retired_partitions(connection: connection).map do |r|
          export!(r[:name], dir: dir, connection: connection)
                 .merge(ok: true)
        rescue VerificationError, SystemCallError, Zlib::Error => e
          { partition: r[:name], ok: false, error: "#{e.class}: #{e.message}" }
        end
      end

      # Drop retired partitions whose export verifies. Anything that fails
      # verification is reported and LEFT ALONE -- the whole point of the
      # manifest is that this step cannot destroy an unbacked partition.
      def drop_exported!(dir:, before: nil, connection: ActiveRecord::Base.connection)
        droppable(before: before, connection: connection).map do |r|
          begin
            verify!(r[:name], dir: dir, connection: connection)
          rescue VerificationError => e
            next { name: r[:name], dropped: false, error: e.message }
          end

          connection.execute("DROP TABLE #{connection.quote_table_name(r[:name])}")
          { name: r[:name], dropped: true, bytes: r[:bytes] }
        end
      end

      # Drop retired partitions WITHOUT checking that an export exists.
      #
      # Deliberately offered. A file in an export directory is not proof the data
      # was preserved, so requiring one buys less safety than it appears to --
      # and forcing every adopter to produce CSV archives they may not want is
      # not this library's decision to make. The judgement that matters, "is this
      # data past its horizon", was already made upstream by `retire!`; this only
      # reclaims the disk it left behind.
      #
      # Still marker-gated, and still keyed on the upper bound: it drops what
      # THIS library retired, and under `before:` only what it can positively
      # date. See Partitions::RETIRED_MARKER.
      def drop_retired!(before: nil, connection: ActiveRecord::Base.connection)
        droppable(before: before, connection: connection).map do |r|
          connection.execute("DROP TABLE #{connection.quote_table_name(r[:name])}")
          { name: r[:name], dropped: true, bytes: r[:bytes] }
        end
      end

      # What a drop would consider, given an optional cutoff.
      #
      # `before` compares the marker's EXCLUSIVE UPPER bound, matching the rule
      # `expired_partitions` follows: keying on the lower bound would drop a
      # partition still holding data on the safe side of the cutoff. A 2025
      # yearly partition ends 2026-01-01, so BEFORE=2025-06-01 correctly leaves
      # it alone.
      #
      # A partition whose marker will not parse has no date, so a date-bounded
      # drop SKIPS it rather than guessing. Without `before` there is nothing to
      # compare and everything marked is in scope.
      def droppable(before:, connection: ActiveRecord::Base.connection)
        retired = AuditLog::Partitions.retired_partitions(connection: connection)
        return retired if before.nil?

        cutoff = before.utc
        retired.select { |r| r[:upper] && r[:upper] <= cutoff }
      end

      def data_path(dir, name)     = File.join(dir, "#{name}.csv.gz")
      def manifest_path(dir, name) = File.join(dir, "#{name}.manifest.json")

      private

      def read_manifest(dir, name)
        path = manifest_path(dir, name)
        JSON.parse(File.read(path)) if File.exist?(path)
      end
    end
  end
end
