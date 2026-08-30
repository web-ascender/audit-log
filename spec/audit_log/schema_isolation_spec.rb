# frozen_string_literal: true

require "rails_helper"

# The library installs into, and operates on, the CURRENT schema -- never a
# hardcoded `public`.
#
# For almost every application there is only one schema and nothing here can
# fail. It is pinned anyway because the failure it guards is the kind this
# library exists to prevent: the writes SUCCEED, against the wrong table, and
# nothing reports it. A trigger function pinned to `public.audit_changes` files
# every schema's history in one table; a provisioning check that asks about
# `public.audit_changes_2026_08` reports "already there" to a caller
# provisioning somewhere else, which then provisions nothing and fails on its
# first write.
#
# Deliberately no tenancy library here -- the same discipline that keeps Devise
# and Solid Queue out of spec/dummy. What is under test is a bare second schema
# and a search_path, which is all this library is entitled to know about.
RSpec.describe "installing into a schema other than public" do
  let(:conn)  { ActiveRecord::Base.connection }
  let(:probe) { "audit_probe" }

  # Everything here rolls back with the example's transaction, DDL included.
  before do
    @original_search_path = conn.select_value("SHOW search_path")
    conn.execute(%(CREATE SCHEMA "#{probe}"))
  end

  after { conn.execute("SET LOCAL search_path = #{@original_search_path}") }

  # A full install of the library, plus one audited business table, in `probe`.
  def install_into_probe!
    in_schema(probe) do
      AuditLog::Schema.install!(conn)
      conn.create_table(:widgets) { |t| t.string :name }
      migration.attach_audit_trigger(:widgets, model: "Widget")
    end
  end

  def in_schema(name)
    conn.execute("SET LOCAL search_path = #{conn.quote_table_name(name)}")
    yield
  ensure
    conn.execute("SET LOCAL search_path = #{@original_search_path}")
  end

  def migration
    @migration ||= ActiveRecord::Migration::Current.new.tap { |m| m.verbose = false }
  end

  def count_in(schema, table = "audit_changes")
    conn.select_value("SELECT count(*) FROM #{conn.quote_table_name(schema)}.#{table}").to_i
  end

  describe "provisioning" do
    it "creates the audit tables and their partitions in the current schema" do
      install_into_probe!

      partitions = conn.select_values(<<~SQL)
        SELECT c.relname
        FROM   pg_class c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        JOIN   pg_inherits i ON i.inhrelid = c.oid
        WHERE  n.nspname = #{conn.quote(probe)}
      SQL

      # The regression this pins: `exists?` used to ask to_regclass for
      # "public.<name>", find public's partition, and skip creating this
      # schema's. The parent then sat there with no partitions at all, and the
      # first audited write died on "no partition of relation ... found for row".
      expect(partitions).to include(a_string_matching(/\Aaudit_changes_\d{4}_\d{2}\z/))
      expect(partitions).to include(a_string_matching(/\Aaudit_events_\d{4}_\d{2}\z/))
    end

    it "installs its own copy of the trigger function, pinned to itself" do
      install_into_probe!

      body = conn.select_value(<<~SQL)
        SELECT pg_get_functiondef(p.oid)
        FROM   pg_proc p
        JOIN   pg_namespace n ON n.oid = p.pronamespace
        WHERE  n.nspname = #{conn.quote(probe)} AND p.proname = 'audit_row_change'
      SQL

      expect(body).to be_present
      expect(body).to include("INSERT INTO #{probe}.audit_changes")
      expect(body).not_to include("INSERT INTO public.audit_changes")
    end

    it "binds each trigger to the function copy in its own schema" do
      install_into_probe!

      expect(trigger_function_for(probe, "widgets")).to eq("#{probe}.audit_row_change")
      expect(trigger_function_for("public", "orders")).to eq("public.audit_row_change")
    end

    def trigger_function_for(schema, table)
      conn.select_value(<<~SQL)
        SELECT p.pronamespace::regnamespace || '.' || p.proname
        FROM   pg_trigger t
        JOIN   pg_class c ON c.oid = t.tgrelid
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        JOIN   pg_proc p ON p.oid = t.tgfoid
        WHERE  NOT t.tgisinternal
          AND  n.nspname = #{conn.quote(schema)}
          AND  c.relname = #{conn.quote(table)}
      SQL
    end
  end

  describe "where the rows land" do
    before { install_into_probe! }

    it "files a write in the schema the audited table lives in" do
      before_public = count_in("public")

      in_schema(probe) { conn.execute("INSERT INTO widgets (name) VALUES ('probe widget')") }

      expect(count_in(probe)).to eq(1)
      expect(count_in("public")).to eq(before_public)
    end

    # The case that decides the design, and the one a search_path-following
    # function gets wrong. A table that lives in another schema is written to
    # while THIS schema's search_path is active -- the shape of any record an
    # application deliberately keeps outside its per-schema data. Its history
    # belongs beside it, not in whichever schema happened to be current.
    it "files a write to another schema's table in THAT schema" do
      before_probe = count_in(probe)

      in_schema(probe) do
        conn.execute(<<~SQL)
          INSERT INTO public.products (sku, name, price_cents, created_at, updated_at)
          VALUES ('CROSS-SCHEMA-1', 'Global', 100, now(), now())
        SQL
      end

      expect(count_in("public")).to be > 0
      expect(count_in(probe)).to eq(before_probe)
      expect(conn.select_value(<<~SQL)).to eq("Product")
        SELECT record_type FROM public.audit_changes
        WHERE diff->'sku'->>1 = 'CROSS-SCHEMA-1'
      SQL
    end

    # `SET search_path = pg_catalog` plus a fully qualified destination. The pin
    # is why the function still cannot be redirected by shadowing its target
    # into an earlier schema -- the property the old `pg_catalog, public` pin
    # provided, kept while the destination stopped being a constant.
    it "cannot be redirected by shadowing audit_changes earlier on the path" do
      conn.execute(%(CREATE SCHEMA "shadow"))
      conn.execute(%(CREATE TABLE "shadow".audit_changes (LIKE #{probe}.audit_changes INCLUDING ALL)))

      conn.execute(%(SET LOCAL search_path = "shadow", #{probe}))
      conn.execute("INSERT INTO #{probe}.widgets (name) VALUES ('hijack attempt')")
      conn.execute("SET LOCAL search_path = #{@original_search_path}")

      expect(count_in("shadow")).to eq(0)
      expect(count_in(probe)).to eq(1)
    end
  end

  describe "AuditLog::Coverage" do
    it "never lets one schema's trigger vouch for another schema's table" do
      install_into_probe!
      # Same table name as an audited table in public, with no trigger of its own.
      in_schema(probe) { conn.create_table(:products) { |t| t.string :sku } }

      in_schema(probe) do
        coverage = AuditLog::Coverage.new(connection: conn)

        expect(coverage.missing).to include("products")
        expect(coverage.audited_tables).to include("widgets")
        expect(coverage.audited_tables).not_to include("orders")
      end
    end
  end

  describe "AuditLog::Partitions inventory" do
    it "reports only the current schema's partitions" do
      install_into_probe!

      in_schema(probe) do
        expect(AuditLog::Partitions.list(connection: conn)).to all(be_present)
        expect(AuditLog::Partitions.list(connection: conn).size)
          .to eq(conn.select_value(<<~SQL).to_i)
            SELECT count(*)
            FROM   pg_class c
            JOIN   pg_namespace n ON n.oid = c.relnamespace
            JOIN   pg_inherits i ON i.inhrelid = c.oid
            JOIN   pg_class p ON p.oid = i.inhparent
            WHERE  n.nspname = #{conn.quote(probe)}
              AND  p.relname IN ('audit_events', 'audit_changes')
          SQL
      end
    end
  end
end
