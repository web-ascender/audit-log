# frozen_string_literal: true

require "rails_helper"

# The three operations a long retention horizon needs, beyond provisioning:
# draining the default partition, consolidating closed years, and retiring
# expired ranges. Every example here runs inside the suite's transaction, so the
# DDL it creates is rolled back with it.
RSpec.describe AuditLog::Partitions, "lifecycle" do
  let(:conn) { ActiveRecord::Base.connection }

  # Written straight to the table rather than through an audited model, because
  # occurred_at is filled by a column DEFAULT that no application code can set --
  # which is the point of utc_storage_spec, and inconvenient here.
  def insert_change(at:, record_id: 1)
    conn.execute(<<~SQL)
      INSERT INTO audit_changes
        (occurred_at, record_type, record_id, operation, diff, changed_columns)
      VALUES
        ('#{at} 12:00:00+00', 'Order', #{record_id}, 'U', '{"status":["a","b"]}', '{status}')
    SQL
  end

  # A genuinely separate backend. The pool cannot provide one: transactional
  # fixtures pin a single connection and hand the same object back to `checkout`.
  def raw_session
    cfg = ActiveRecord::Base.connection_db_config.configuration_hash

    # Every credential the pool was given, PASSWORD INCLUDED. Omitting it worked
    # for as long as the only database this ran against was a local one with trust
    # authentication -- and then failed the moment CI pointed it at a server that
    # asks ("fe_sendauth: no password supplied"). A developer whose local Postgres
    # requires a password would have hit exactly the same thing.
    session = PG.connect(host: cfg[:host], port: cfg[:port],
                         dbname: cfg[:database], user: cfg[:username],
                         password: cfg[:password])
    yield session
  ensure
    session&.close
  end

  def advisory_locks_held
    ActiveRecord::Base.connection.uncached do
      ActiveRecord::Base.connection.select_value(<<~SQL).to_i
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND pid = pg_backend_pid()
      SQL
    end
  end

  def partition_names_for(table)
    described_class.list.select { |n| n.start_with?("#{table}_") }
  end

  describe ".drain_default!" do
    # A row whose month has no partition lands in the default one, and while it
    # sits there Postgres refuses to create the partition that should hold it.
    # That is the deadlock drain_default! exists to break.
    it "breaks the deadlock that makes the rows unmovable by hand" do
      insert_change(at: "2019-03-15")
      expect(described_class.overflow_count["audit_changes"]).to eq(1)

      expect {
        described_class.create_month!("audit_changes", Date.new(2019, 3, 1))
      }.to raise_error(ActiveRecord::StatementInvalid, /default partition/)
    end

    it "moves the row and creates the partition" do
      insert_change(at: "2019-03-15")

      result = described_class.drain_default!

      expect(result["audit_changes"][:moved]).to eq(1)
      expect(result["audit_changes"][:created]).to include("audit_changes_2019_03")
      expect(described_class.overflow_count["audit_changes"]).to eq(0)
      expect(conn.select_value("SELECT count(*) FROM audit_changes_2019_03").to_i).to eq(1)
    end

    it "preserves the row's id, so nothing that referenced it dangles" do
      insert_change(at: "2019-03-15")
      id = conn.select_value("SELECT id FROM audit_changes_default").to_i

      described_class.drain_default!

      expect(conn.select_value("SELECT id FROM audit_changes_2019_03").to_i).to eq(id)
    end

    it "files a row under its UTC month, not the session's" do
      # 23:30 UTC on the 31st is still the 31st in UTC and already the 1st
      # nowhere -- but 00:30 UTC on the 1st is the previous month in every US
      # zone. Only the UTC answer keeps the row inside its partition's bounds.
      insert_original = conn.select_value("SHOW TimeZone")
      conn.execute("SET TIME ZONE 'America/Detroit'")
      conn.execute(<<~SQL)
        INSERT INTO audit_changes
          (occurred_at, record_type, record_id, operation, diff, changed_columns)
        VALUES ('2019-04-01 00:30:00+00', 'Order', 1, 'U', '{}', '{}')
      SQL

      described_class.drain_default!

      expect(described_class.list).to include("audit_changes_2019_04")
      expect(conn.select_value("SELECT count(*) FROM audit_changes_2019_04").to_i).to eq(1)
    ensure
      conn.execute("SET TIME ZONE #{conn.quote(insert_original)}")
    end

    it "is a no-op on a healthy default partition" do
      expect(described_class.drain_default!.values.map { |r| r[:moved] }).to all(eq(0))
    end
  end

  # Freezing had no specs at all until it started running daily, which is exactly
  # when it needed them.
  #
  # VACUUM CANNOT RUN INSIDE A TRANSACTION, and every example here runs in one, so
  # the VACUUM statement is swallowed and the assertions are about SELECTION and
  # MARKING -- which is where all the logic is. Whether Postgres freezes pages
  # correctly is not this suite's business.
  describe ".freeze_closed!" do
    before do
      allow(conn).to receive(:execute).and_wrap_original do |orig, sql, *rest|
        sql.to_s.strip.start_with?("VACUUM") ? sql : orig.call(sql, *rest)
      end
    end

    it "freezes a closed partition and records that it did" do
      described_class.create_month!("audit_changes", Date.new(2015, 1, 1))

      expect(described_class.freeze_closed!).to include("audit_changes_2015_01")
      expect(described_class.frozen_partitions).to include("audit_changes_2015_01")
    end

    # THE PROPERTY THAT MAKES THE DAILY TASK SAFE. Without it this is unbounded
    # work that grows with the retention horizon, plus an ANALYZE re-sampling
    # statistics that cannot have changed -- which is what forced an operator to
    # decide when to run it.
    it "does no work on a second run" do
      described_class.create_month!("audit_changes", Date.new(2015, 1, 1))
      described_class.freeze_closed!

      expect(described_class.freeze_closed!).to eq([])
    end

    it "redoes marked partitions when forced, for when a marker is wrong" do
      described_class.create_month!("audit_changes", Date.new(2015, 1, 1))
      described_class.freeze_closed!

      expect(described_class.freeze_closed!(force: true)).to include("audit_changes_2015_01")
    end

    # The current month is still being written to; freezing it would be undone by
    # the next insert.
    it "leaves the current month alone" do
      current = described_class.partition_name("audit_changes", Date.today.beginning_of_month)
      described_class.create_month!("audit_changes", Date.today.beginning_of_month)

      expect(described_class.freeze_closed!).not_to include(current)
    end

    # THE INTERACTION THAT WOULD OTHERWISE BITE SILENTLY. Redaction UPDATEs the
    # PARENT table, so it reaches every attached partition -- including closed
    # ones already frozen, whose pages it dirties. Left marked, such a partition
    # is never frozen again and the anti-wraparound vacuum that freezing exists
    # to pre-empt arrives anyway, on a table everybody believed was handled.
    #
    # A drain, by contrast, needs no such handling and that is worth knowing:
    # Postgres refuses an insert into the default partition whose range another
    # partition claims, so a drain's targets are always partitions it created a
    # moment ago -- new, and therefore unfrozen.
    it "is undone by a redaction, which dirties whatever partitions it touched" do
      described_class.create_month!("audit_changes", Date.new(2015, 1, 1))
      described_class.freeze_closed!
      expect(described_class.frozen_partitions).to include("audit_changes_2015_01")

      AuditLog::Redaction.redact_record!(record_type: "Order", record_id: 1, reason: "DSR-1")

      expect(described_class.frozen_partitions).not_to include("audit_changes_2015_01")
      expect(described_class.freeze_closed!).to include("audit_changes_2015_01")
    end
  end

  describe "retention" do
    before { described_class.create_month!("audit_changes", Date.new(2015, 1, 1)) }

    it "expires a partition whose whole range is past the horizon" do
      names = described_class.expired_partitions(retention: 7.years).map { |b| b[:name] }
      expect(names).to include("audit_changes_2015_01")
    end

    # The upper bound, not the lower: keying on the lower bound would expire a
    # month that still holds days inside the horizon.
    it "does not expire a partition still holding in-horizon rows" do
      names = described_class.expired_partitions(retention: 7.years).map { |b| b[:name] }
      current = described_class.partition_name("audit_changes", Time.now.utc.to_date)
      expect(names).not_to include(current)
    end

    it "expires nothing when retention is disabled" do
      expect(described_class.expired_partitions(retention: nil)).to eq([])
    end

    it "detaches and renames rather than dropping, by default" do
      described_class.retire!(retention: 7.years)

      expect(described_class.list).not_to include("audit_changes_2015_01")
      expect(described_class.retired_partitions.map { |r| r[:name] })
        .to include("audit_changes_retired_2015_01")
    end

    # A detached partition keeps its rows and its disk. Anything that reported
    # otherwise would be telling an auditor data was destroyed when it was not.
    it "keeps the data reachable under the retired name" do
      insert_change(at: "2015-01-10")
      described_class.drain_default!
      described_class.retire!(retention: 7.years)

      expect(conn.select_value("SELECT count(*) FROM audit_changes_retired_2015_01").to_i).to eq(1)
      expect(conn.select_value(<<~SQL).to_i).to eq(0)
        SELECT count(*) FROM audit_changes
        WHERE occurred_at >= '2015-01-01+00' AND occurred_at < '2015-02-01+00'
      SQL
    end

    # There is no longer an option to drop here, and that is the point: a config
    # attribute meant one line in an initializer could turn a SCHEDULED task into
    # one that destroys audit data. A safe default is weaker than an absent
    # option, because a default can be flipped.
    it "cannot destroy data, whatever it is asked" do
      insert_change(at: "2015-01-10")
      described_class.drain_default!
      described_class.retire!(retention: 7.years)

      expect(described_class.retire!(retention: 7.years)).to eq([])
      expect(conn.select_value("SELECT to_regclass('public.audit_changes_retired_2015_01')::text"))
        .to eq("audit_changes_retired_2015_01")
      expect(conn.select_value("SELECT count(*) FROM audit_changes_retired_2015_01").to_i).to eq(1)
    end

    # DETACH clears relpartbound, so retiring destroys the authoritative record
    # of what period a partition covers. The marker captures it first -- and is
    # also the only proof the partition is ours to drop.
    it "stamps the partition with its provenance and its upper bound" do
      described_class.retire!(retention: 7.years)

      comment = conn.select_value(<<~SQL)
        SELECT obj_description('public.audit_changes_retired_2015_01'::regclass, 'pg_class')
      SQL
      expect(comment).to start_with(described_class::RETIRED_MARKER)

      retired = described_class.retired_partitions.find { |r| r[:name] == "audit_changes_retired_2015_01" }
      expect(retired[:upper]).to eq(Time.utc(2015, 2, 1))
    end

    # A name is not proof. `audit_changes_retired_2019_01` is a name anybody can
    # create, and a manual copy taken before a risky migration is the obvious way
    # it happens -- dropping on a name match would destroy it.
    it "ignores a lookalike table it did not retire, and reports it" do
      conn.execute("CREATE TABLE audit_changes_retired_1999_01 (id bigint)")

      expect(described_class.retired_partitions.map { |r| r[:name] })
        .not_to include("audit_changes_retired_1999_01")
      expect(described_class.unmarked_retired.map { |r| r[:name] })
        .to include("audit_changes_retired_1999_01")
    ensure
      conn.execute("DROP TABLE IF EXISTS audit_changes_retired_1999_01")
    end
  end

  describe "rollup" do
    before do
      (1..12).each { |m| described_class.create_month!("audit_changes", Date.new(2019, m, 1)) }
    end

    it "offers a closed year stored as months" do
      candidates = described_class.rollup_candidates(older_than: 2.years)
      year = candidates.find { |c| c[:table] == "audit_changes" && c[:year] == 2019 }

      expect(year[:partitions].size).to eq(12)
    end

    it "does not offer a year that is still inside the window" do
      candidates = described_class.rollup_candidates(older_than: 100.years)
      expect(candidates).to eq([])
    end

    it "offers nothing when rollup is disabled" do
      expect(described_class.rollup_candidates(older_than: nil)).to eq([])
    end

    context "after rolling one year up" do
      before do
        insert_change(at: "2019-02-14", record_id: 1)
        insert_change(at: "2019-08-20", record_id: 2)
        insert_change(at: "2019-12-31", record_id: 3)
        @result = described_class.rollup_year!("audit_changes", 2019)
      end

      it "replaces twelve partitions with one" do
        expect(@result[:name]).to eq("audit_changes_2019")
        expect(@result[:replaced].size).to eq(12)
        expect(partition_names_for("audit_changes")).to include("audit_changes_2019")
        expect(partition_names_for("audit_changes").grep(/2019_\d\d/)).to be_empty
      end

      it "keeps every row, still reachable through the parent" do
        expect(@result[:rows]).to eq(3)
        expect(conn.select_value(<<~SQL).to_i).to eq(3)
          SELECT count(*) FROM audit_changes
          WHERE occurred_at >= '2019-01-01+00' AND occurred_at < '2020-01-01+00'
        SQL
      end

      it "covers exactly the calendar year on UTC midnight boundaries" do
        bound = described_class.partition_bounds.find { |b| b[:name] == "audit_changes_2019" }

        expect(bound[:lower]).to eq(Time.utc(2019, 1, 1))
        expect(bound[:upper]).to eq(Time.utc(2020, 1, 1))
        expect(described_class.misaligned_bounds).to eq([])
      end

      # LIKE ... INCLUDING ALL is what carries these across, and it is also what
      # lets ATTACH match them to the parent's partitioned indexes instead of
      # rebuilding them while holding an exclusive lock.
      it "carries the parent's indexes onto the yearly partition" do
        current = described_class.partition_name("audit_changes", Time.now.utc.to_date)
        counts = [current, "audit_changes_2019"].map do |table|
          conn.select_value("SELECT count(*) FROM pg_indexes WHERE tablename = #{conn.quote(table)}").to_i
        end

        expect(counts.last).to eq(counts.first)
        expect(counts.last).to be_positive
        expect(conn.select_values(<<~SQL).join).to include("gin")
          SELECT indexdef FROM pg_indexes WHERE tablename = 'audit_changes_2019'
        SQL
      end

      # Assert pruning, not which index was chosen -- see CLAUDE.md.
      it "still prunes: a one-month query reads only the yearly partition" do
        plan = conn.select_values(<<~SQL).join("\n")
          EXPLAIN SELECT * FROM audit_changes
          WHERE occurred_at >= '2019-08-01+00' AND occurred_at < '2019-09-01+00'
        SQL

        expect(plan).to include("audit_changes_2019")
        expect(plan).not_to match(/audit_changes_20(2[0-9]|1[0-8])/)
      end

      it "leaves the redundant bound CHECK off the attached partition" do
        constraints = conn.select_values(<<~SQL)
          SELECT conname FROM pg_constraint
          WHERE conrelid = 'audit_changes_2019'::regclass AND contype = 'c'
        SQL
        expect(constraints).not_to include("audit_changes_2019_bound")
      end

      it "will not roll the same year up twice" do
        expect { described_class.rollup_year!("audit_changes", 2019) }
          .to raise_error(AuditLog::Error, /already a partition/)
        expect(described_class.rollup_candidates(older_than: 2.years).map { |c| c[:year] })
          .not_to include(2019)
      end
    end

    # The one piece of logic here whose failure mode is SILENT DATA LOSS: a row
    # written into the year between the copy and the swap would otherwise be
    # dropped along with the monthly partition holding it. Forcing the watermark
    # low makes every copied row look like a late arrival, which is the same code
    # path a real late arrival takes.
    describe "the late-write guard" do
      before do
        (1..12).each { |m| described_class.create_month!("audit_changes", Date.new(2019, m, 1)) }
        insert_change(at: "2019-06-15")
        allow(described_class).to receive(:rollup_watermark).and_return(0)
      end

      it "refuses the swap rather than dropping the row" do
        expect { described_class.rollup_year!("audit_changes", 2019) }
          .to raise_error(AuditLog::Error, /not closed/)
      end

      it "leaves the twelve monthly partitions attached and the row intact" do
        described_class.rollup_year!("audit_changes", 2019)
      rescue AuditLog::Error
        expect(partition_names_for("audit_changes").grep(/2019_\d\d/).size).to eq(12)
        expect(partition_names_for("audit_changes")).not_to include("audit_changes_2019")
        expect(conn.select_value(<<~SQL).to_i).to eq(1)
          SELECT count(*) FROM audit_changes
          WHERE occurred_at >= '2019-01-01+00' AND occurred_at < '2020-01-01+00'
        SQL
      end
    end

    describe "debris from an interrupted run" do
      before { (1..12).each { |m| described_class.create_month!("audit_changes", Date.new(2019, m, 1)) } }

      # An unattached audit_changes_2019 is either our own leftover -- safe to
      # recreate -- or a table this library did not make, in which case dropping
      # it destroys data. Only the marker tells them apart.
      it "refuses to drop an unmarked table occupying the target name" do
        conn.execute("CREATE TABLE audit_changes_2019 (LIKE audit_changes)")

        expect { described_class.rollup_year!("audit_changes", 2019) }
          .to raise_error(AuditLog::Error, /carries no rollup marker/)
        expect(conn.select_value("SELECT to_regclass('public.audit_changes_2019')::text")).to be_present
      end

      it "reclaims its own marked debris and reports it until then" do
        conn.execute("CREATE TABLE audit_changes_2019 (LIKE audit_changes)")
        conn.execute("COMMENT ON TABLE audit_changes_2019 IS #{conn.quote(described_class::ROLLUP_MARKER)}")

        expect(described_class.orphaned_rollups.map { |o| o[:name] }).to eq(["audit_changes_2019"])
        expect { described_class.rollup_year!("audit_changes", 2019) }.not_to raise_error
        expect(described_class.orphaned_rollups).to eq([])
      end
    end

    describe "maintenance mutual exclusion" do
      # drain_default! reinserts relocated rows under their ORIGINAL ids, which
      # are below any watermark taken later -- so a drain running inside a rollup
      # would slip a row past the late-write guard. The operations must not
      # overlap.
      # A raw second SESSION, not a second pooled connection: advisory locks are
      # re-entrant within a session, and under transactional fixtures the pool
      # pins one connection and hands the same object back to `checkout`. The
      # case that matters is two processes -- two rake tasks, or a cron
      # overlapping a console -- so the test has to be two backends.
      it "refuses to start while another session holds the lock" do
        raw_session do |other|
          expect(other.exec("SELECT pg_try_advisory_lock(#{described_class::MAINTENANCE_LOCK_KEY})")
                      .getvalue(0, 0)).to eq("t")

          expect { described_class.drain_default! }
            .to raise_error(AuditLog::Error, /already running/)
          expect { described_class.retire!(retention: 7.years) }
            .to raise_error(AuditLog::Error, /already running/)
          expect { described_class.rollup_year!("audit_changes", 2019) }
            .to raise_error(AuditLog::Error, /already running/)
        end
      end

      # The regression guard for a bug this suite could not have caught: RSpec runs
      # with the query cache OFF, while web requests, jobs and `rails runner` all
      # run with it ON. pg_try_advisory_lock is a SELECT with a side effect, so
      # the cache served the second acquire a stale `true` while the session held
      # no lock -- mutual exclusion that reported success and did nothing.
      it "acquires a real lock even with the query cache enabled" do
        conn.cache do
          # A retire! with nothing expired issues no `execute` at all, so nothing
          # clears the cache between its acquire and the next one -- which is what
          # makes this the path that actually exposed the bug. (drain_default!
          # hides it: it runs DDL, and DDL invalidates the cache.)
          described_class.retire!(retention: 100.years)
          expect(advisory_locks_held).to eq(0)

          raw_session do |other|
            other.exec("SELECT pg_try_advisory_lock(#{described_class::MAINTENANCE_LOCK_KEY})")

            # Served from the cache, this returns a stale `true` and no error is
            # raised while the session holds no lock.
            expect { described_class.retire!(retention: 100.years) }
              .to raise_error(AuditLog::Error, /already running/)
          end
        end
      end

      it "releases the lock when the operation raises" do
        allow(described_class).to receive(:expired_partitions).and_raise(AuditLog::Error, "boom")

        expect { described_class.retire!(retention: 7.years) }
          .to raise_error(AuditLog::Error, /boom/)

        expect(conn.select_value("SELECT pg_try_advisory_lock(#{described_class::MAINTENANCE_LOCK_KEY})"))
          .to be(true)
        conn.select_value("SELECT pg_advisory_unlock(#{described_class::MAINTENANCE_LOCK_KEY})")
      end
    end

    # How this state really arises: a June row lands in the default partition
    # because June's was missing, and the rotation job then provisions every
    # month of that year EXCEPT June, which it cannot create while those rows sit
    # there. Rolling the year up would ATTACH over the stranded rows and fail
    # mid-swap; catching it up front points at the fix instead.
    it "refuses to roll up a year the default partition still holds rows for" do
      insert_change(at: "2020-06-15")
      ((1..12).to_a - [6]).each { |m| described_class.create_month!("audit_changes", Date.new(2020, m, 1)) }

      expect(described_class.overflow_count["audit_changes"]).to eq(1)
      expect { described_class.rollup_year!("audit_changes", 2020) }
        .to raise_error(AuditLog::Error, /drain_default/)
    end
  end
end
