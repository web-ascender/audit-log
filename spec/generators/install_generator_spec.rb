# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "generators/audit_log/install/install_generator"

# Generator specs, because `rails generate audit_log:install` is the first thing a
# new host app runs and the only thing standing between "installed" and "installed
# with every audit row carrying a NULL actor".
#
# Two of these examples exist because the generator got them WRONG first time, in
# ways that would not have shown up until an auditor asked who did something:
# the ControllerContext include landed at the top of the class, ahead of
# authenticate_user!, and the schema_format injection landed at column 0.
RSpec.describe AuditLog::Generators::InstallGenerator do
  def run_generator(args = [], dir:)
    output = StringIO.new
    orig, $stdout = $stdout, output
    described_class.start(args, destination_root: dir)
    output.string
  ensure
    $stdout = orig
  end

  def host_app(schema_rb: false, controller: <<~RUBY, jobs: true, spec_dir: true)
    class ApplicationController < ActionController::Base
      before_action :authenticate_user!
      before_action :set_locale
    end
  RUBY
    dir = Dir.mktmpdir("audit_log_host")
    FileUtils.mkdir_p(File.join(dir, "config"))
    FileUtils.mkdir_p(File.join(dir, "app/controllers"))
    FileUtils.mkdir_p(File.join(dir, "db"))
    FileUtils.mkdir_p(File.join(dir, "spec")) if spec_dir

    File.write(File.join(dir, "config/application.rb"), <<~RUBY)
      module HostApp
        class Application < Rails::Application
          config.load_defaults 8.1
        end
      end
    RUBY
    File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
    File.write(File.join(dir, "app/controllers/application_controller.rb"), controller)
    if jobs
      FileUtils.mkdir_p(File.join(dir, "app/jobs"))
      File.write(File.join(dir, "app/jobs/application_job.rb"),
                 "class ApplicationJob < ActiveJob::Base\nend\n")
    end
    File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema[8.1].define\n") if schema_rb
    dir
  end

  def read(dir, path) = File.read(File.join(dir, path))
  def migration(dir)  = Dir[File.join(dir, "db/migrate/*_install_audit_log.rb")].first

  describe "a clean install" do
    let(:dir) { host_app }
    before { run_generator([], dir: dir) }
    after  { FileUtils.remove_entry(dir) }

    it "writes the initializer, the migration and the coverage spec" do
      expect(read(dir, "config/initializers/audit_log.rb")).to include("AuditLog.configure")
      expect(migration(dir)).not_to be_nil
      expect(read(dir, "spec/audit_log/coverage_spec.rb"))
        .to include('it_behaves_like "an app with complete audit coverage"')
    end

    # THE ONE THAT MATTERS. ControllerContext is `included do before_action ... end`,
    # so the include's position in the class body decides callback order. Ahead of
    # authenticate_user! it reads a current_user that is not resolved yet, and every
    # audit row in the application gets a NULL actor. Silently.
    it "puts the ControllerContext include AFTER the last before_action" do
      body  = read(dir, "app/controllers/application_controller.rb")
      lines = body.lines.map(&:strip)

      include_at = lines.index("include AuditLog::ControllerContext")
      last_hook  = lines.rindex { |l| l.start_with?("before_action") }

      expect(include_at).not_to be_nil
      expect(include_at).to be > last_hook
    end

    it "says out loud that the include's position needs confirming" do
      expect(run_generator([], dir: host_app)).to include("AFTER whatever establishes current_user")
    end

    it "indents the injected schema_format to match the class body" do
      expect(read(dir, "config/application.rb"))
        .to match(/^    config\.active_record\.schema_format = :sql$/)
    end

    it "does not leave trailing whitespace behind" do
      expect(read(dir, "config/application.rb")).not_to match(/[ \t]+$/)
    end

    it "mounts the engine" do
      expect(read(dir, "config/routes.rb")).to include('mount AuditLog::Engine => "/audit", as: :audit')
    end

    it "generates valid Ruby" do
      %w[config/initializers/audit_log.rb config/application.rb
         app/controllers/application_controller.rb spec/audit_log/coverage_spec.rb].each do |f|
        expect(system("ruby", "-c", File.join(dir, f), out: File::NULL, err: File::NULL))
          .to be(true), "#{f} is not valid Ruby"
      end
      expect(system("ruby", "-c", migration(dir), out: File::NULL, err: File::NULL)).to be(true)
    end

    it "targets the running Rails version in the migration" do
      expect(File.read(migration(dir)))
        .to include("ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]")
    end

    it "is idempotent: a second run injects nothing twice" do
      run_generator([], dir: dir)

      body = read(dir, "app/controllers/application_controller.rb")
      expect(body.scan("include AuditLog::ControllerContext").size).to eq(1)
      expect(read(dir, "config/routes.rb").scan("AuditLog::Engine").size).to eq(1)
      expect(read(dir, "config/application.rb").scan("schema_format").size).to eq(1)
    end
  end

  describe "an app that already has db/schema.rb" do
    let(:dir) { host_app(schema_rb: true) }
    after { FileUtils.remove_entry(dir) }

    # Refusing is the feature. :sql is required BEFORE the first migration, so
    # switching an established app means re-dumping its whole schema and every
    # developer rebuilding their database. A generator must not start that quietly.
    it "refuses to change schema_format, and leaves application.rb untouched" do
      before_content = read(dir, "config/application.rb")
      output = run_generator([], dir: dir)

      expect(read(dir, "config/application.rb")).to eq(before_content)
      expect(output).to include("db/schema.rb exists, so schema_format was NOT changed")
      expect(output).to include("config.active_record.schema_format = :sql")
    end
  end

  describe "an app missing the files it wants to touch" do
    let(:dir) { host_app(jobs: false, spec_dir: false) }
    after { FileUtils.remove_entry(dir) }

    # Reporting the gap is the whole point: a silently skipped JobContext include
    # means every background job writes rows with no actor and no cause.
    it "reports each one as manual with the exact line to add" do
      output = run_generator([], dir: dir)

      expect(output).to include("app/jobs/application_job.rb not found")
      expect(output).to include("include AuditLog::JobContext")
      expect(output).to include("no spec/ directory")
      expect(output).to include('it_behaves_like "an app with complete audit coverage"')
    end
  end

  describe "options" do
    it "honours --mount-at" do
      dir = host_app
      run_generator(["--mount-at=/internal/audit"], dir: dir)

      expect(read(dir, "config/routes.rb")).to include('=> "/internal/audit"')
    ensure
      FileUtils.remove_entry(dir)
    end

    it "honours the skip flags" do
      dir = host_app
      run_generator(%w[--skip-routes --skip-controller --skip-job --skip-migration --skip-spec], dir: dir)

      expect(read(dir, "config/routes.rb")).not_to include("AuditLog::Engine")
      expect(read(dir, "app/controllers/application_controller.rb")).not_to include("AuditLog")
      expect(Dir[File.join(dir, "db/migrate/*")]).to be_empty
      expect(File.exist?(File.join(dir, "spec/audit_log/coverage_spec.rb"))).to be(false)
      expect(read(dir, "config/initializers/audit_log.rb")).to include("AuditLog.configure")
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  # The generated initializer is the file a host app reads first, and its default
  # authorize hook is the difference between a gated audit console and a public one.
  describe "the generated initializer" do
    it "ships an authorize hook that denies rather than a no-op" do
      dir = host_app
      run_generator([], dir: dir)
      body = read(dir, "config/initializers/audit_log.rb")

      expect(body).to include("config.authorize")
      expect(body).to include("ActionController::RoutingError")
      expect(body).to match(/NO-OP|no-op/)
    ensure
      FileUtils.remove_entry(dir)
    end

    it "leaves the registry empty but explains that notify without an entry is a no-op" do
      dir = host_app
      run_generator([], dir: dir)
      body = read(dir, "config/initializers/audit_log.rb")

      expect(body).to include("AuditLog::Registry.clear!")
      expect(body).to include("SILENT NO-OP")
    ensure
      FileUtils.remove_entry(dir)
    end
  end
end
