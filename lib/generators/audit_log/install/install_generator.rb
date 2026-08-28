# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"

module AuditLog
  module Generators
    # `rails generate audit_log:install`
    #
    # Automates the integration steps in README.md. The design rule it follows is
    # the same one the library follows: NEVER REPORT SUCCESS FOR WORK IT DID NOT
    # DO. A generator that silently skips the ApplicationController include leaves
    # an app whose audit rows all have a NULL actor, and nothing anywhere says so
    # -- which is precisely the failure mode this whole library exists to prevent.
    #
    # So every step reports one of: created, injected, skipped-because-already-
    # present, or MANUAL, and the manual ones are collected and printed again at
    # the end with the exact line to add.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Install the audit log: initializer, schema migration, integration points, coverage spec."

      class_option :mount_at, type: :string, default: "/audit",
                              desc: "Where to mount the auditor UI"
      class_option :skip_migration, type: :boolean, default: false
      class_option :skip_routes,     type: :boolean, default: false
      class_option :skip_controller, type: :boolean, default: false
      class_option :skip_job,        type: :boolean, default: false
      class_option :skip_spec,       type: :boolean, default: false

      ORDER_WARNING = <<~TEXT
        ControllerContext registers a before_action. If it runs before your
        authentication does, current_user is not resolved yet and EVERY audit row
        gets a NULL actor -- with nothing anywhere reporting it.
      TEXT

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      # ---------------------------------------------------------------- step 1
      # schema_format, and the one place this generator deliberately refuses.
      def configure_schema_format
        app = "config/application.rb"

        unless file_exists?(app)
          return manual("#{app} not found",
                        "config.active_record.schema_format = :sql")
        end

        if read(app).include?("schema_format")
          return skip("#{app} already sets schema_format — check it is :sql")
        end

        # REFUSE rather than flip. :sql is required before the first migration
        # exists; switching an app that already has a db/schema.rb means its
        # entire schema has to be re-dumped as SQL, every developer has to rebuild
        # their database, and any migration that ran in between is unaccounted
        # for. That is a decision for a human with a plan, not a generator.
        if file_exists?("db/schema.rb")
          return manual(
            "db/schema.rb exists, so schema_format was NOT changed",
            "config.active_record.schema_format = :sql",
            <<~WHY
              This app already has a Ruby schema dump. AuditLog requires :sql,
              because schema.rb cannot represent partitioned tables, trigger
              functions or triggers -- all three of which layer 1 is built from.
              Switching is disruptive and is not something to do behind your back:
                1. set the option above
                2. bin/rails db:migrate  (regenerates db/structure.sql)
                3. delete db/schema.rb, and commit both changes together
            WHY
          )
        end

        inject_into_class app, "Application", <<~RUBY.gsub(/^(?=.)/, "    ")
          # REQUIRED by audit_log, and required before the first migration:
          # schema.rb cannot represent partitioned tables, trigger functions or
          # triggers. Never convert back, and never hand-edit db/structure.sql.
          config.active_record.schema_format = :sql

        RUBY
      end

      # ---------------------------------------------------------------- step 2
      def create_initializer
        template "initializer.rb", "config/initializers/audit_log.rb"
      end

      # ---------------------------------------------------------------- step 3
      def create_install_migration
        return if options[:skip_migration]

        migration_template "install_migration.rb", "db/migrate/install_audit_log.rb"
      rescue Rails::Generators::Error => e
        # migration_template raises when a migration of the same name exists.
        skip("install_audit_log migration already exists (#{e.message})")
      end

      # ---------------------------------------------------------------- step 4
      # ORDER MATTERS HERE, which is why this does not just call `integrate`.
      #
      # ControllerContext is `included do before_action :set_audit_context end`, so
      # the position of the include in the class body decides callback order.
      # inject_into_class puts it at the TOP, ahead of `before_action
      # :authenticate_user!` -- and then set_audit_context runs before
      # authentication, reads a current_user that is not established yet, and every
      # audit row in the application gets a NULL actor. Silently.
      #
      # So: land it after the LAST before_action when the class has any, and ask
      # the operator to confirm the position either way.
      def integrate_controller
        return if options[:skip_controller]

        path = "app/controllers/application_controller.rb"
        line = "include AuditLog::ControllerContext"

        return manual("#{path} not found", line, ORDER_WARNING) unless file_exists?(path)
        return skip("#{path} already has #{line}") if read(path).include?(line)

        content = read(path)
        lines   = content.lines
        idx     = lines.rindex { |l| l.match?(/^\s*(?:prepend_)?before_action\b/) }
        anchor  = idx && lines[idx]

        if anchor && content.scan(anchor).size == 1
          indent = anchor[/\A[ \t]*/]
          inject_into_file path, "#{indent}#{line}\n", after: anchor
        else
          # No before_action to anchor to, or the line is ambiguous. Top of the
          # class is then as good a guess as any -- but say so.
          inject_into_class path, "ApplicationController", "  #{line}\n"
        end

        verify("#{path}: confirm `#{line}` sits AFTER whatever establishes current_user",
               ORDER_WARNING)
      end

      # ---------------------------------------------------------------- step 5
      def integrate_job
        return if options[:skip_job]

        integrate "app/jobs/application_job.rb", "ApplicationJob",
                  "include AuditLog::JobContext"
      end

      # ---------------------------------------------------------------- step 6
      def mount_engine
        return if options[:skip_routes]

        line = %(mount AuditLog::Engine => "#{options[:mount_at]}", as: :audit)

        if !file_exists?("config/routes.rb")
          manual("config/routes.rb not found", line)
        elsif read("config/routes.rb").include?("AuditLog::Engine")
          skip("config/routes.rb already mounts AuditLog::Engine")
        else
          route line
        end
      end

      # ---------------------------------------------------------------- step 7
      def create_coverage_spec
        return if options[:skip_spec]

        unless File.directory?(File.join(destination_root, "spec"))
          return manual(
            "no spec/ directory, so the coverage spec was not created",
            'it_behaves_like "an app with complete audit coverage"',
            <<~WHY
              This is the forcing function: without it, a table added later with no
              audit trigger and no written exemption fails nothing. If you use
              Minitest, assert AuditLog::Coverage.new.ok? in a test instead --
              `rake audit_log:coverage` is the same check for CI.
            WHY
          )
        end

        template "coverage_spec.rb", "spec/audit_log/coverage_spec.rb"
      end

      # ---------------------------------------------------------------- report
      def report
        say ""
        say "  AuditLog installed.", :green
        say ""

        if verifications.any?
          say "  Check #{verifications.size} thing#{"s" if verifications.size != 1}:", :yellow
          verifications.each do |what, why|
            say ""
            say "  * #{what}", :yellow
            why.to_s.each_line { |l| say "    #{l.chomp}" } if why
          end
          say ""
        end

        if notes.any?
          say "  #{notes.size} thing#{"s" if notes.size != 1} need#{"s" if notes.size == 1} you:", :yellow
          notes.each do |what, line, why|
            say ""
            say "  * #{what}", :yellow
            say "    add: #{line}", :yellow if line
            why.to_s.each_line { |l| say "    #{l.chomp}" } if why
          end
          say ""
        end

        say "  Two steps nobody can generate for you:", :yellow
        say ""
        say "  1. Attach a trigger to each audited table. One line per table, and the"
        say "     entire per-model cost of this design:"
        say ""
        say "       rails generate audit_log:trigger orders --model=Order"
        say ""
        say "     Which tables deserve auditing is a judgement about your domain, so"
        say "     it cannot be inferred. spec/audit_log/coverage_spec.rb is what stops"
        say "     the judgement being skipped rather than made."
        say ""
        say "  2. Schedule `rake audit_log:partitions` daily."
        say ""
        say "     A MISSING FUTURE PARTITION IS A WRITE-PATH OUTAGE, not a degraded"
        say "     report. Nothing else in the lifecycle belongs in a cron -- the other"
        say "     tasks take ACCESS EXCLUSIVE on an audit table and block every"
        say "     audited write in the app."
        say ""
        say "  Then: bin/rails db:migrate && bin/rails audit_log:coverage"
        say ""
        say "  Read config/initializers/audit_log.rb before deploying. config.authorize"
        say "  defaults to a NO-OP, which is right for a demo and wrong for you.", :red
        say ""
      end

      private

      def notes
        @notes ||= []
      end

      # Work that WAS done but that a human has to confirm. Kept separate from
      # `manual`, because "I did this, check it" and "I could not do this" are
      # different messages and collapsing them trains people to ignore both.
      def verifications
        @verifications ||= []
      end

      def verify(what, why = nil)
        verifications << [what, why]
      end

      def manual(what, line = nil, why = nil)
        notes << [what, line, why]
        say_status :manual, what, :yellow
      end

      def skip(what)
        say_status :skip, what, :blue
      end

      def file_exists?(path)
        File.exist?(File.join(destination_root, path))
      end

      def read(path)
        File.read(File.join(destination_root, path))
      end

      # One include, reported honestly in all four possible outcomes.
      def integrate(path, klass, line, note = nil)
        return manual("#{path} not found", line, note) unless file_exists?(path)
        return skip("#{path} already has #{line}") if read(path).include?(line)

        inject_into_class path, klass, "  #{line}\n"
      end

      def migration_version
        "[#{::ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
