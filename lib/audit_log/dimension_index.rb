# frozen_string_literal: true

module AuditLog
  # THE RETROFIT PATH for the facet index, and nothing else. DESIGN §23.
  #
  # A new application never comes here: `audit_tables.sql` creates the index with
  # the tables, against nothing, and it is free for the life of that application
  # if the feature is never used. This module exists for the other case -- an
  # established deployment with years of audit rows already in place, where the
  # obvious spelling is a write-path outage.
  #
  # WHY THE PER-PARTITION DANCE. `CREATE INDEX CONCURRENTLY` is REFUSED on a
  # partitioned table, verified on 18.6:
  #
  #   ERROR:  cannot create index on partitioned table "p" concurrently
  #
  # So `add_index :audit_changes, :dimensions, using: :gin` builds across every
  # partition under a lock that blocks every audited write in the application for
  # the duration -- on a seven-year horizon, a GIN build over 84 partitions. The
  # supported shape instead is:
  #
  #   CREATE INDEX audit_changes_dimensions_idx ON ONLY audit_changes  -- no build
  #     USING gin (dimensions jsonb_path_ops) WHERE dimensions IS NOT NULL;
  #   CREATE INDEX CONCURRENTLY audit_changes_2026_08_dimensions_idx ON audit_changes_2026_08 ...;
  #   ALTER INDEX audit_changes_dimensions_idx ATTACH PARTITION audit_changes_2026_08_dimensions_idx;
  #
  # POSTGRES TRACKS COMPLETENESS ITSELF, which is the property that makes this
  # safe rather than merely fiddly. The parent index sits at `indisvalid = false`
  # and flips to true at the moment the LAST partition attaches. `complete?`
  # asserts that rather than counting partitions and trusting its own arithmetic
  # -- DESIGN §21.1's "never report success for work it did not do", enforced by
  # the catalog instead of by care.
  #
  # `disable_ddl_transaction!` IS MANDATORY in the migration that calls this,
  # because CONCURRENTLY cannot run inside a transaction. A failure therefore
  # leaves partial state, which is exactly why `complete?` matters and why
  # `install!` is re-runnable: it skips partitions already attached, and drops
  # the INVALID partition index a failed CONCURRENTLY leaves behind before
  # retrying it.
  #
  # NOTHING IN §8 HAS TO LEARN THIS EXISTS. A partition created after the parent
  # index exists inherits it (verified), so `Partitions.ensure!` and the daily
  # task are untouched; `rollup_year!` builds its staging table with
  # `LIKE ... INCLUDING ALL`, so a yearly partition acquires the facet index
  # without the rollup code knowing about this feature; a retired partition takes
  # its indexes with it; and `drain_default!`'s temp table needs none.
  module DimensionIndex
    TABLES = %w[audit_events audit_changes].freeze

    # Same name the install migration creates, so a retrofitted database and a
    # freshly installed one are indistinguishable afterwards.
    def self.parent_index(table) = "#{table}_dimensions_idx"

    def self.partition_index(partition) = "#{partition}_dimensions_idx"

    class << self
      # Yields [table, partition, action] as it goes -- :parent, :created,
      # :skipped or :retried -- because a migration that prints nothing while
      # building 84 GIN indexes is indistinguishable from one that has hung.
      #
      # Returns the tables it finished, so a caller can assert against the same
      # thing the catalog says.
      def install!(connection: ActiveRecord::Base.connection, tables: TABLES, &block)
        Array(tables).each do |table|
          create_parent!(table, connection: connection, &block)

          partitions(table, connection: connection).each do |partition|
            attach!(table, partition, connection: connection, &block)
          end
        end

        Array(tables).select { |t| complete?(t, connection: connection) }
      end

      # The catalog's own answer, not ours. `indisvalid` on a partitioned index
      # is false until every partition has attached one, and Postgres is the only
      # thing that knows that for certain.
      def complete?(table, connection: ActiveRecord::Base.connection)
        connection.select_value(<<~SQL) == true
          SELECT i.indisvalid
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          JOIN   pg_index i ON i.indexrelid = c.oid
          WHERE  c.relname = #{connection.quote(parent_index(table))}
            AND  n.nspname = current_schema()
        SQL
      end

      # For an operator asking "did that finish?" without re-running it.
      def status(connection: ActiveRecord::Base.connection, tables: TABLES)
        Array(tables).to_h do |table|
          [table, { parent: index_exists?(parent_index(table), connection: connection),
                    complete: complete?(table, connection: connection),
                    pending: partitions(table, connection: connection).reject { |p|
                      attached?(p, connection: connection)
                    } }]
        end
      end

      private

      def create_parent!(table, connection:)
        name = parent_index(table)
        return if index_exists?(name, connection: connection)

        # ON ONLY: the parent catalog entry alone, with no build and no scan. It
        # is created INVALID by construction and becomes valid when the last
        # partition attaches below.
        connection.execute(<<~SQL)
          CREATE INDEX #{connection.quote_table_name(name)}
            ON ONLY #{connection.quote_table_name(table)}
            USING gin (dimensions jsonb_path_ops)
            WHERE dimensions IS NOT NULL;
        SQL
        yield(table, nil, :parent) if block_given?
      end

      def attach!(table, partition, connection:)
        name = partition_index(partition)

        if attached?(partition, connection: connection)
          yield(table, partition, :skipped) if block_given?
          return
        end

        # A previous run that died mid-CONCURRENTLY leaves an INVALID index
        # behind. It can never become valid on its own and it cannot be attached,
        # so it is debris and dropping it is the only way forward. Dropped
        # CONCURRENTLY too, so the retry costs no more lock than the first
        # attempt did.
        #
        # `attached?` ABOVE IS WHAT MAKES THIS SAFE, and the reason is a property
        # of Postgres rather than of care: an ATTACHED child index cannot be
        # dropped at all while its parent exists --
        #
        #   ERROR:  cannot drop index audit_changes_2026_09_dimensions_idx
        #           because index audit_changes_dimensions_idx requires it
        #
        # -- so the debris state is reachable only BEFORE the ATTACH, which is
        # exactly the case that gets here. Verified on 18.6, not reasoned about;
        # without the gate this line would try to drop working indexes on every
        # re-run and fail loudly instead of skipping them.
        action = :created
        if index_exists?(name, connection: connection)
          connection.execute("DROP INDEX CONCURRENTLY IF EXISTS #{connection.quote_table_name(name)};")
          action = :retried
        end

        connection.execute(<<~SQL)
          CREATE INDEX CONCURRENTLY #{connection.quote_table_name(name)}
            ON #{connection.quote_table_name(partition)}
            USING gin (dimensions jsonb_path_ops)
            WHERE dimensions IS NOT NULL;
        SQL
        connection.execute(<<~SQL)
          ALTER INDEX #{connection.quote_table_name(parent_index(table))}
            ATTACH PARTITION #{connection.quote_table_name(name)};
        SQL

        yield(table, partition, action) if block_given?
      end

      # current_schema()-scoped, for the reason every other catalog query in this
      # library is: a name match alone lets one schema's state answer a question
      # asked about another's. DESIGN §14.
      def partitions(table, connection:)
        connection.select_values(<<~SQL)
          SELECT c.relname
          FROM   pg_class c
          JOIN   pg_inherits i ON i.inhrelid = c.oid
          JOIN   pg_class p ON p.oid = i.inhparent
          JOIN   pg_namespace n ON n.oid = p.relnamespace
          WHERE  p.relname = #{connection.quote(table)}
            AND  n.nspname = current_schema()
          ORDER  BY c.relname
        SQL
      end

      # Attached to the PARENT INDEX, which is a different question from "an
      # index of that name exists": a failed CONCURRENTLY leaves one that exists
      # and is attached to nothing.
      def attached?(partition, connection:)
        connection.select_value(<<~SQL).present?
          SELECT c.relname
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          JOIN   pg_inherits i ON i.inhrelid = c.oid
          WHERE  c.relname = #{connection.quote(partition_index(partition))}
            AND  n.nspname = current_schema()
        SQL
      end

      def index_exists?(name, connection:)
        connection.select_value(<<~SQL).present?
          SELECT c.relname
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  c.relname = #{connection.quote(name)}
            AND  n.nspname = current_schema()
            AND  c.relkind IN ('i', 'I')
        SQL
      end
    end
  end
end
