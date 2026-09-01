# frozen_string_literal: true

module AuditLog
  # Included into ActiveRecord::Migration by the engine, so every migration can
  # call attach_audit_trigger without a require.
  #
  # This one line, next to the create_table it audits, is the ENTIRE per-model
  # cost of this design. There is no `has_audit_log`, no `include Auditable`, no
  # callback, and no base-class requirement -- which is precisely why update_all,
  # delete_all, raw SQL and database-level cascades cannot escape it.
  #
  # Attaching is deliberately explicit rather than automatic-by-default: auditing
  # every table would sweep in solid_queue_*, sessions, and every join table --
  # high-churn tables with no compliance value that would dominate the audit
  # volume and bury real findings. The coverage spec is what keeps "explicit"
  # from degrading into "forgotten".
  module MigrationHelpers
    # `dimensions:` names COLUMNS ON THIS TABLE whose values are recorded onto
    # every audit_changes row the trigger writes, so a host can ask "everything
    # that happened to invoices in department 5" -- a question this library
    # cannot pose on its own, because the facet is the host's. DESIGN §23.
    #
    #   attach_audit_trigger :invoices, model: "Invoice",
    #     dimensions: %i[organization_id customer_id department_id]
    #
    # EXPLICIT ONLY -- there is deliberately no `dimensions: :auto`. Sweeping in
    # every `%_id` column is genuinely tempting and its failure mode is invisible:
    # it takes `stripe_charge_id` and `external_uuid` along with the real
    # associations, and a high-cardinality text id in a GIN index produces one
    # entry per row, which is that index's worst case, arrived at silently, on the
    # largest table in the database. An opt-in feature whose cost curve depends on
    # columns nobody chose is not opt-in.
    #
    # Changing the set is detach-then-attach, exactly as changing `exclude:` is,
    # and it is NOT retroactive: removing a facet stops recording it from that
    # migration forward, and rows already written keep it and go on matching.
    def attach_audit_trigger(table, model: nil, exclude: [], dimensions: [])
      model ||= table.to_s.classify
      cols   = (AuditLog.config.default_excluded_columns + exclude.map(&:to_s)).uniq
      facets = Array(dimensions).map(&:to_s).uniq

      validate_identifiers!(cols)
      validate_identifiers!(facets)
      validate_dimension_columns!(table, facets)

      # TG_ARGV[2] is OMITTED, not passed empty, when no facet is declared. The
      # trigger function's extraction block is guarded on `TG_ARGV[2] IS NOT
      # NULL`, so a table that declares none pays nothing for the ones that do --
      # which is what makes this free for a non-adopter, since one function
      # serves every audited table in the schema.
      args = [quote(cols.join(",")), quote(model)]
      args << quote(facets.join(",")) if facets.any?

      # The function is named UNQUALIFIED, so it resolves through search_path at
      # CREATE TRIGGER time and Postgres records the OID it resolved to -- the
      # binding is permanent from then on. That means a trigger is attached to
      # the copy of the function installed alongside it by the same migration
      # run, under the same search_path, which is what keeps a row's audit
      # trail in the schema the row lives in. Qualifying it `public.` here is
      # what used to send every schema's writes to one table.
      #
      # If no audit_row_change is visible, CREATE TRIGGER fails, loudly, during
      # the migration. That is the intended outcome: the alternative to a
      # missing function is a silent one.
      execute <<~SQL
        CREATE TRIGGER #{trigger_name(table)}
        AFTER INSERT OR UPDATE OR DELETE ON #{quote_table_name(table)}
        FOR EACH ROW EXECUTE FUNCTION audit_row_change(
          #{args.join(", ")}
        );
      SQL
    end

    def detach_audit_trigger(table)
      execute "DROP TRIGGER IF EXISTS #{trigger_name(table)} ON #{quote_table_name(table)};"
    end

    def trigger_name(table)
      "#{table}_audit"
    end

    # THE TUNING STEP, when one facet turns out to be on every screen. GIN can
    # filter but cannot ORDER, so `ORDER BY occurred_at DESC LIMIT 25` under a
    # GIN-only plan fetches every match in the window and sorts it; a btree
    # expression index restores index-ordered keyset paging for the hot facet and
    # leaves the rest as filters. Promotion to a real column (DESIGN §14's
    # tenant_id recipe) remains available above this. DESIGN §23.
    #
    # It builds on the PARENT of a partitioned table, which takes a lock that
    # blocks the audit write path for the duration -- so on an established
    # deployment, run it in the same window as the rest of §8's maintenance. On a
    # new application the tables are empty and it is instant.
    def add_audit_dimension_index(key, tables: AuditLog::Partitions::TABLES)
      validate_identifiers!([key.to_s])

      Array(tables).each do |table|
        execute <<~SQL
          CREATE INDEX #{dimension_index_name(table, key)} ON #{quote_table_name(table)}
            ((dimensions ->> #{quote(key.to_s)}), occurred_at DESC)
            WHERE dimensions IS NOT NULL;
        SQL
      end
    end

    def remove_audit_dimension_index(key, tables: AuditLog::Partitions::TABLES)
      validate_identifiers!([key.to_s])

      Array(tables).each do |table|
        execute "DROP INDEX IF EXISTS #{dimension_index_name(table, key)};"
      end
    end

    def dimension_index_name(table, key)
      "#{table}_dim_#{key}_idx"
    end

    private

    # The column list is interpolated into a string literal that plpgsql splits on
    # commas, so a comma or quote in a column name would corrupt the exclusion
    # list rather than merely fail. Refuse anything that is not a plain identifier.
    def validate_identifiers!(cols)
      bad = cols.reject { |c| c.match?(/\A[a-z_][a-z0-9_]*\z/i) }
      return if bad.empty?

      raise ArgumentError, "Not valid column identifiers: #{bad.inspect}"
    end

    # THE ONLY ENFORCEMENT IN THE ENTIRE FEATURE, and it is here rather than at
    # runtime for the reason CREATE TRIGGER already raises when the function is
    # not visible: a typo'd `deparment_id` otherwise records a dimension that is
    # absent forever, and the symptom is a filter that returns nothing and never
    # says why. One SELECT in a migration, nothing at runtime.
    #
    # Everything else about dimensions is deliberately unenforced -- no coverage
    # rule, no `required_dimensions`, no backfill, no raise. A facet adds nothing
    # to what is RECORDED, only to what is findable in one query, so a missing one
    # is a question nobody asked rather than a hole in the log. Forcing functions
    # belong on the second kind. DESIGN §23.
    def validate_dimension_columns!(table, facets)
      return if facets.empty?

      known = select_values(<<~SQL)
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = current_schema()
           AND table_name   = #{quote(table.to_s)}
      SQL

      missing = facets - known.map(&:to_s)
      return if missing.empty?

      raise ArgumentError, <<~MESSAGE
        attach_audit_trigger #{table.to_s.inspect} declares dimensions #{missing.inspect}, \
        which #{missing.one? ? "is not a column" : "are not columns"} on that table.

          declared: #{facets.inspect}
          columns:  #{known.sort.inspect}

        A dimension is read straight off the changed row by the trigger, so a name
        that is not a column records nothing -- forever, and without saying so. The
        filter that name was added for would return an empty screen and never
        explain why, which is why this is checked here rather than discovered later.
      MESSAGE
    end
  end
end
