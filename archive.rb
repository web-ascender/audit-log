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
      def export!(name, dir:, connection: ActiveRecord::Base.connection)
        FileUtils.mkdir_p(dir)
        raw    = connection.raw_connection
        digest = Digest::SHA256.new
        rows   = 0

        File.open(data_path(dir, name), "wb") do |file|
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
            gz.close
          end
        end

        manifest = {
          format_version: FORMAT_VERSION,
          partition:      name,
          rows:           rows - 1, # the HEADER line
          sha256:         digest.hexdigest,
          bytes:          File.size(data_path(dir, name)),
          exported_at:    Time.now.utc.iso8601,
          columns:        connection.columns(name).map(&:name)
        }
        File.write(manifest_path(dir, name), JSON.pretty_generate(manifest))
        manifest
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

      def exported?(name, dir:)
        File.exist?(data_path(dir, name)) && File.exist?(manifest_path(dir, name))
      end

      # Export every retired partition that has not been exported yet.
      def export_retired!(dir:, connection: ActiveRecord::Base.connection)
        AuditLog::Partitions.retired_partitions(connection: connection).filter_map do |r|
          next if exported?(r[:name], dir: dir)

          export!(r[:name], dir: dir, connection: connection)
        end
      end

      # Drop retired partitions whose export verifies. Anything that fails
      # verification is reported and LEFT ALONE -- the whole point of the
      # manifest is that this step cannot destroy an unbacked partition.
      def drop_exported!(dir:, connection: ActiveRecord::Base.connection)
        AuditLog::Partitions.retired_partitions(connection: connection).map do |r|
          begin
            verify!(r[:name], dir: dir, connection: connection)
          rescue VerificationError => e
            next { name: r[:name], dropped: false, error: e.message }
          end

          connection.execute("DROP TABLE #{connection.quote_table_name(r[:name])}")
          { name: r[:name], dropped: true, bytes: r[:bytes] }
        end
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
