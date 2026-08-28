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
    def attach_audit_trigger(table, model: nil, exclude: [])
      model ||= table.to_s.classify
      cols = (AuditLog.config.default_excluded_columns + exclude.map(&:to_s)).uniq

      validate_identifiers!(cols)
      execute <<~SQL
        CREATE TRIGGER #{trigger_name(table)}
        AFTER INSERT OR UPDATE OR DELETE ON #{quote_table_name(table)}
        FOR EACH ROW EXECUTE FUNCTION public.audit_row_change(
          #{quote(cols.join(","))}, #{quote(model)}
        );
      SQL
    end

    def detach_audit_trigger(table)
      execute "DROP TRIGGER IF EXISTS #{trigger_name(table)} ON #{quote_table_name(table)};"
    end

    def trigger_name(table)
      "#{table}_audit"
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
  end
end
