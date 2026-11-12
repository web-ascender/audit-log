# frozen_string_literal: true

require "rails_helper"
require "rake"

# The scheduled routines, the jobs that run them from a queue, and the rake tasks
# that run them from a shell. One routine, three callers -- so what is asserted
# here is that each caller surfaces a problem through the channel its environment
# actually watches: a job by FAILING, a rake task by PRINTING.
#
# Every example runs inside the suite's transaction, so the DDL is rolled back.
# VACUUM cannot run inside one, so it is swallowed, as in partition_lifecycle_spec.
RSpec.describe AuditLog::Maintenance do
  let(:conn) { ActiveRecord::Base.connection }
  let(:reporter) { collecting_reporter }

  def collecting_reporter
    Class.new do
      attr_reader :lines

      def initialize = @lines = []
      def info(message)    = @lines << [:info, message]
      def note(message)    = @lines << [:note, message]
      def warning(message) = @lines << [:warning, message]
      def of(level)        = @lines.select { |l, _| l == level }.map(&:last)
    end.new
  end

  # Outside every partition the daily run provisions, so ensure! will not try to
  # create its month and fail on the row -- the row just sits in the default.
  def misfile_a_row
    conn.execute(<<~SQL)
      INSERT INTO audit_changes (occurred_at, record_type, record_id, operation, diff, changed_columns)
      VALUES ('2099-01-15 12:00:00+00', 'Order', 1, 'U', '{}', '{}')
    SQL
  end

  before do
    allow(conn).to receive(:execute).and_wrap_original do |orig, sql, *rest|
      sql.to_s.strip.start_with?("VACUUM") ? sql : orig.call(sql, *rest)
    end
  end

  describe ".rotate_partitions!" do
    it "creates what is missing and says so" do
      furthest = AuditLog::Partitions.partition_name(
        "audit_changes", Time.now.utc.to_date.beginning_of_month >> AuditLog.config.partition_months_ahead
      )
      conn.execute("DROP TABLE #{furthest}")

      result = described_class.rotate_partitions!(reporter: reporter)

      expect(result[:created]).to eq([furthest])
      expect(reporter.of(:info)).to include("Created: #{furthest}")
    end

    it "freezes a newly closed month" do
      AuditLog::Partitions.create_month!("audit_changes", Date.new(2015, 1, 1))

      result = described_class.rotate_partitions!(reporter: reporter)

      expect(result[:frozen]).to include("audit_changes_2015_01")
      expect(AuditLog::Partitions.frozen_partitions).to include("audit_changes_2015_01")
    end

    it "is quiet and raises nothing on a healthy layout" do
      expect { described_class.rotate_partitions!(reporter: reporter) }.not_to raise_error
      expect(reporter.of(:warning)).to be_empty
    end

    # THE JOB'S CHANNEL. A warning in a worker log is a scheduler discarding
    # output, so the run fails -- with a message that says what to run.
    it "raises MaintenanceWarning on a misfiled row, naming the repair" do
      misfile_a_row

      expect { described_class.rotate_partitions!(reporter: reporter) }
        .to raise_error(AuditLog::MaintenanceWarning, /1 row\(s\) in audit_changes_default.*drain_default/)
    end

    it "raises on a boundary off UTC midnight" do
      conn.execute(<<~SQL)
        CREATE TABLE audit_changes_2033_01 PARTITION OF audit_changes
        FOR VALUES FROM ('2033-01-01 00:00:00-05') TO ('2033-02-01 00:00:00-05')
      SQL

      expect { described_class.rotate_partitions!(reporter: reporter) }
        .to raise_error(AuditLog::MaintenanceWarning, /audit_changes_2033_01 is not UTC-aligned/)
    end

    # Raised AFTER the work, so a misfiled row never costs a closed month its freeze.
    it "finishes the run before raising" do
      AuditLog::Partitions.create_month!("audit_changes", Date.new(2015, 1, 1))
      misfile_a_row

      expect { described_class.rotate_partitions!(reporter: reporter) }
        .to raise_error(AuditLog::MaintenanceWarning)
      expect(AuditLog::Partitions.frozen_partitions).to include("audit_changes_2015_01")
    end

    context "when the freeze fails" do
      before do
        allow(AuditLog::Partitions).to receive(:freeze_closed!)
          .and_raise(ActiveRecord::StatementInvalid, "VACUUM failed")
      end

      # The freeze runs LAST, so everything there is to say has been said by the
      # time a VACUUM can raise -- notes included.
      it "has already reported every warning and note" do
        misfile_a_row
        conn.execute("CREATE TABLE audit_changes_2019 (LIKE audit_changes)")
        conn.execute("COMMENT ON TABLE audit_changes_2019 IS #{conn.quote(AuditLog::Partitions::ROLLUP_MARKER)}")

        expect { described_class.rotate_partitions!(reporter: reporter) }.to raise_error(AuditLog::Error)
        expect(reporter.of(:warning)).to include(a_string_matching(/audit_changes_default/))
        expect(reporter.of(:note)).to include(a_string_matching(/audit_changes_2019 is a staging table/))
      end

      # Otherwise the job fails as a VACUUM error and the misfiled rows -- the
      # finding that needs a person -- exist only in the worker log.
      it "raises the warning, carrying the VACUUM error as its cause" do
        misfile_a_row

        expect { described_class.rotate_partitions!(reporter: reporter) }
          .to raise_error(AuditLog::MaintenanceWarning) { |error|
            expect(error.message).to match(/audit_changes_default.*then failed: ActiveRecord::StatementInvalid: VACUUM failed/)
            expect(error.warnings).to contain_exactly(a_string_matching(/audit_changes_default/))
            expect(error.cause).to be_a(ActiveRecord::StatementInvalid)
          }
      end

      it "raises the VACUUM error itself when there was nothing to warn about" do
        expect { described_class.rotate_partitions!(reporter: reporter) }
          .to raise_error(ActiveRecord::StatementInvalid, /VACUUM failed/)
      end

      # The rake task's mode: the warning is already on stderr.
      it "raises the VACUUM error itself when not raising on warnings" do
        misfile_a_row

        expect { described_class.rotate_partitions!(reporter: reporter, raise_on_warnings: false) }
          .to raise_error(ActiveRecord::StatementInvalid, /VACUUM failed/)
      end
    end

    # In a loop over tenants a bare `audit_changes_default` says which table and
    # not whose. Off `public` only, so a single-schema app reads as it always has.
    it "names the schema when it is not public" do
      misfile_a_row
      allow(conn).to receive(:select_value).and_call_original
      allow(conn).to receive(:select_value).with("SELECT current_schema()").and_return("acme")

      expect { described_class.rotate_partitions!(reporter: reporter) }
        .to raise_error(AuditLog::MaintenanceWarning, /1 row\(s\) in acme\.audit_changes_default/)
    end

    it "leaves names unqualified in public" do
      misfile_a_row

      described_class.rotate_partitions!(reporter: reporter, raise_on_warnings: false)

      expect(reporter.of(:warning)).to include(a_string_starting_with("1 row(s) in audit_changes_default"))
    end

    it "hands warnings back instead when told not to raise -- the rake task's mode" do
      misfile_a_row

      result = described_class.rotate_partitions!(reporter: reporter, raise_on_warnings: false)

      expect(result[:warnings]).to contain_exactly(a_string_matching(/audit_changes_default/))
    end

    # Disk awaiting a human decision. Failing the daily job over it every day
    # would teach a team to ignore the one job whose failure means an outage.
    it "notes leftovers without raising" do
      conn.execute("CREATE TABLE audit_changes_2019 (LIKE audit_changes)")
      conn.execute("COMMENT ON TABLE audit_changes_2019 IS #{conn.quote(AuditLog::Partitions::ROLLUP_MARKER)}")
      conn.execute("CREATE TABLE audit_changes_retired_1999_01 (id bigint)")

      expect { described_class.rotate_partitions!(reporter: reporter) }.not_to raise_error
      expect(reporter.of(:note)).to include(
        a_string_matching(/audit_changes_2019 is a staging table.*audit_log:partitions:rollup/),
        a_string_matching(/audit_changes_retired_1999_01 looks retired/)
      )
    end
  end

  describe ".retire_partitions!" do
    before { AuditLog::Partitions.create_month!("audit_changes", Date.new(2015, 1, 1)) }

    it "does nothing, and says why, when retention is disabled" do
      allow(AuditLog.config).to receive(:retention).and_return(nil)

      expect(described_class.retire_partitions!(reporter: reporter)).to eq([])
      expect(reporter.of(:info)).to eq(["Retention is disabled (AuditLog.config.retention is nil)."])
    end

    it "lists without detaching on a dry run" do
      described_class.retire_partitions!(reporter: reporter, dry_run: true)

      expect(reporter.of(:info)).to include(a_string_matching(/would detach: audit_changes_2015_01/))
      expect(AuditLog::Partitions.list).to include("audit_changes_2015_01")
    end

    it "reports each partition as it is retired" do
      retired = described_class.retire_partitions!(reporter: reporter)

      expect(retired.map { |r| r[:retired_as] }).to include("audit_changes_retired_2015_01")
      expect(reporter.of(:info)).to include("  detached: audit_changes_2015_01 -> audit_changes_retired_2015_01")
      expect(reporter.of(:note)).to include(a_string_matching(/still hold their data/))
    end
  end

  describe ".roll_up_partitions!" do
    it "does nothing, and says why, when rollup is disabled" do
      allow(AuditLog.config).to receive(:rollup_after).and_return(nil)

      expect(described_class.roll_up_partitions!(reporter: reporter)).to eq([])
      expect(reporter.of(:info)).to eq(["Rollup is disabled (AuditLog.config.rollup_after is nil)."])
    end

    it "lists without rewriting on a dry run" do
      AuditLog::Partitions.create_month!("audit_changes", Date.new(2019, 3, 1))

      described_class.roll_up_partitions!(reporter: reporter, dry_run: true)

      expect(reporter.of(:info)).to include("audit_changes 2019: 1 monthly partition(s) -> audit_changes_2019")
      expect(AuditLog::Partitions.list).to include("audit_changes_2019_03")
    end

    it "reports each year as it is rolled up" do
      AuditLog::Partitions.create_month!("audit_changes", Date.new(2019, 3, 1))

      results = described_class.roll_up_partitions!(reporter: reporter)

      expect(results.map { |r| r[:name] }).to eq(["audit_changes_2019"])
      expect(reporter.of(:info)).to include(a_string_matching(/\A  audit_changes_2019: 0 row\(s\)/))
    end
  end

  describe AuditLog::Maintenance::LogReporter do
    it "logs every level, prefixed so a log search finds it" do
      logger = instance_double(Logger, info: nil, warn: nil)
      reporter = described_class.new(logger: logger)

      reporter.info("did a thing")
      reporter.note("disk held")
      reporter.warning("rows misfiled")

      expect(logger).to have_received(:info).with("[AuditLog] did a thing")
      expect(logger).to have_received(:warn).with("[AuditLog] NOTE: disk held")
      expect(logger).to have_received(:warn).with("[AuditLog] WARNING: rows misfiled")
    end
  end

  describe "the jobs" do
    # Named from a schedule file as a string, so constantizing one is the first
    # thing Solid Queue or sidekiq-cron does with it.
    it "are ActiveJob classes a schedule can name" do
      %w[AuditLog::RotatePartitions AuditLog::RetirePartitions AuditLog::RollUpPartitions].each do |name|
        expect(name.constantize.superclass).to eq(ActiveJob::Base)
      end
    end

    # A named queue nobody consumes leaves the daily job enqueued forever, and
    # the first symptom is the outage it exists to prevent.
    it "use the queue every worker consumes by default" do
      expect(AuditLog::RotatePartitions.new.queue_name).to eq("default")
    end

    # Under the query cache, which a real worker runs with and RSpec does not --
    # the trap CLAUDE.md records for SELECTs with side effects.
    it "fail the daily job on a misfiled row" do
      misfile_a_row

      expect { conn.cache { AuditLog::RotatePartitions.perform_now } }
        .to raise_error(AuditLog::MaintenanceWarning)
    end

    it "run retention and rollup through the shared routines" do
      allow(described_class).to receive(:retire_partitions!)
      allow(described_class).to receive(:roll_up_partitions!)

      AuditLog::RetirePartitions.perform_now
      AuditLog::RollUpPartitions.perform_now

      expect(described_class).to have_received(:retire_partitions!).with(no_args)
      expect(described_class).to have_received(:roll_up_partitions!).with(no_args)
    end

    # The rake tasks reach Maintenance and Partitions, so a reference to
    # ActiveJob anywhere on that path would break them in an app that never
    # loaded it. And a job under app/ would be eager-loaded at boot in every host,
    # naming ActiveJob::Base whether or not anybody schedules it.
    #
    # So: nothing outside the three job files names ActiveJob::Base, and nothing
    # on the rake path names the jobs. job_context.rb is the one other mention,
    # and it is a concern a host includes into its OWN job -- `included do` runs
    # only there.
    it "are the only code that names ActiveJob::Base, and the rake path never reaches them" do
      root = Pathname(AuditLog::GEM_ROOT)
      code = ->(path) { path.read.lines.reject { |l| l.strip.start_with?("#") }.join }
      jobs = %w[rotate_partitions retire_partitions roll_up_partitions].map { |f| root.join("lib/audit_log/#{f}.rb") }
      sources = root.glob("{app,lib}/**/*.{rb,rake}") - jobs

      expect(sources.select { |f| code.call(f).include?("ActiveJob::Base") }).to be_empty

      rake_path = [root.join("lib/audit_log/tasks/audit_log.rake"),
                   root.join("lib/audit_log/maintenance.rb"),
                   root.join("lib/audit_log/partitions.rb")]
      job_names = /RotatePartitions|RetirePartitions|RollUpPartitions|ActiveJob/
      expect(rake_path.select { |f| code.call(f).match?(job_names) }).to be_empty
    end
  end

  describe "the rake tasks" do
    before(:all) do
      Rails.application.load_tasks unless Rake::Task.task_defined?("audit_log:partitions")
    end

    def run(task)
      Rake::Task[task].reenable
      Rake::Task[task].invoke
    end

    # THE CRON'S CHANNEL. Same routine, but the warning is printed and the task
    # exits 0, as it always has.
    it "print a warning to stderr instead of failing" do
      misfile_a_row

      expect { run("audit_log:partitions") }
        .to output(/WARNING: 1 row\(s\) in audit_changes_default/).to_stderr
        .and output(/All partitions present/).to_stdout
    end

    it "pass DRY_RUN through to retention" do
      AuditLog::Partitions.create_month!("audit_changes", Date.new(2015, 1, 1))
      ENV["DRY_RUN"] = "1"

      expect { run("audit_log:partitions:retention") }.to output(/would detach: audit_changes_2015_01/).to_stdout
      expect(AuditLog::Partitions.list).to include("audit_changes_2015_01")
    ensure
      ENV.delete("DRY_RUN")
    end
  end
end
