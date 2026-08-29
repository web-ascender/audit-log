# frozen_string_literal: true

require "rails/generators"

module AuditLog
  module Generators
    module Views
      # `rails generate audit_log:views:activity Order Product Customer`
      #
      # The auditor UI at /audit is for auditors. This generates the OTHER screen:
      # an activity history a host app renders on its own pages, for people who
      # should not hold the auditor role. It is the reference implementation
      # (`../audit-log-demo`) extracted into templates, so an adopting app starts
      # from something that already gets the awkward parts right rather than
      # rediscovering them.
      #
      # What it produces is YOURS. Edit it freely -- it is deliberately plain Rails
      # with no gem-side indirection, and nothing here is re-generated or upgraded
      # later. The parts worth not undoing are called out in comments in the files
      # themselves.
      #
      # SAME RULE AS THE INSTALL GENERATOR: never report success for work it did
      # not do. Every step says created, injected, skipped-because-already-present,
      # or MANUAL, and the manual ones are printed again at the end.
      class ActivityGenerator < Rails::Generators::Base
        source_root File.expand_path("templates", __dir__)

        desc <<~DESC
          Generate a record activity history: controller, concern, helper, views, route.
          Pass the model names whose histories may be read, e.g. Order Product Customer.
        DESC

        argument :models, type: :array, default: [], banner: "Order Product Customer"

        class_option :path, type: :string, default: "activity",
                            desc: "URL prefix for the history page"
        class_option :css, type: :string, default: "plain",
                           enum: %w[plain tailwind bootstrap],
                           desc: "Class names to emit in the generated markup"
        class_option :skip_views,  type: :boolean, default: false
        class_option :skip_css,    type: :boolean, default: false
        class_option :skip_routes, type: :boolean, default: false
        class_option :skip_locale, type: :boolean, default: false
        class_option :skip_show_pages, type: :boolean, default: false,
                                       desc: "Do not touch the models' show pages"

        # SAME MARKUP, different class attributes. The structure of the generated
        # views does not change with --css: only what goes in `class=`. That is the
        # point -- the semantics (which element is the card, which is the before
        # value) stay legible whichever framework a host uses, and a host switching
        # frameworks later rewrites strings rather than re-deriving the view.
        #
        # `plain` also ships a stylesheet. `tailwind` and `bootstrap` ship none:
        # they assume the framework is already working and add nothing to install.
        CLASSES = {
          "plain" => {
            feed: "activity-feed", card: "activity", narrated: "narrated", bare: "bare",
            redacted: "redacted", meta: "meta", headline: "headline", who: "who",
            details: "fields-block", fields: "fields", fname: "fname", arrow: "arrow",
            record_list: "record-list", payload: "payload", empty: "empty",
            badge: "badge", chip: "col-chip", muted: "assoc-failed",
            redaction_note: "redaction-note", note: "note", note_small: "note small",
            note_warn: "note warn", page_head: "page-head", actions: "actions",
            button: "btn", pagination: "pagination", small: "small", small_muted: "small muted"
          },
          "tailwind" => {
            feed: "list-none m-0 p-0 pl-6 border-l border-gray-200",
            card: "relative rounded-lg border border-gray-200 bg-white px-4 py-3 mb-3",
            narrated: "border-l-4 border-l-emerald-700", bare: "border-l-4 border-l-gray-200",
            redacted: "bg-amber-50 border-amber-200",
            meta: "flex flex-wrap items-center gap-2 text-xs text-gray-500 mb-1.5",
            headline: "m-0 mb-1 text-[15px] leading-normal",
            who: "m-0 text-xs text-gray-500",
            details: "mt-2 text-[13px]", fields: "list-none m-0 p-0 grid gap-x-3 gap-y-1",
            fname: "text-gray-500 break-words", arrow: "text-gray-300 text-center",
            record_list: "list-none m-0 p-0 text-[13px]",
            payload: "grid grid-cols-[minmax(90px,170px)_1fr] gap-x-3 gap-y-1 text-[13px]",
            empty: "text-gray-500 italic py-2",
            badge: "inline-block rounded-full border border-gray-200 bg-gray-50 px-2 py-px text-[11px] whitespace-nowrap",
            chip: "rounded bg-gray-100 px-1.5 py-px text-[11px]",
            muted: "text-amber-700 text-[11px] italic",
            redaction_note: "mt-2 text-[13px] text-amber-800 border-l-2 border-amber-200 pl-2",
            note: "text-[13px] text-gray-500 my-1 max-w-prose",
            note_small: "text-xs text-gray-500 my-1 max-w-prose",
            note_warn: "text-[13px] text-amber-800 my-1 max-w-prose",
            page_head: "flex items-start gap-4 mb-3", actions: "flex flex-wrap gap-2",
            button: "inline-block rounded-md border border-gray-200 px-3 py-1.5 text-[13px]",
            pagination: "flex items-center gap-3 my-4",
            small: "text-xs", small_muted: "text-xs text-gray-500"
          },
          "bootstrap" => {
            feed: "list-unstyled mb-2 ps-4 border-start",
            card: "position-relative card card-body mb-3 py-3",
            narrated: "border-start border-4 border-success", bare: "border-start border-4 border-light",
            redacted: "bg-warning-subtle border-warning-subtle",
            meta: "d-flex flex-wrap align-items-center gap-2 small text-body-secondary mb-1",
            headline: "mb-1", who: "mb-0 small text-body-secondary",
            details: "mt-2 small", fields: "list-unstyled mb-0 d-grid gap-1",
            fname: "text-body-secondary", arrow: "text-body-tertiary text-center",
            record_list: "list-unstyled mb-0 small", payload: "row small mb-0",
            empty: "text-body-secondary fst-italic py-2",
            badge: "badge rounded-pill text-bg-light border",
            chip: "badge text-bg-light", muted: "text-warning-emphasis small fst-italic",
            redaction_note: "alert alert-warning py-1 px-2 small mt-2 mb-0",
            note: "small text-body-secondary", note_small: "small text-body-secondary",
            note_warn: "alert alert-warning py-1 px-2 small",
            page_head: "d-flex align-items-start gap-3 mb-3", actions: "d-flex flex-wrap gap-2",
            button: "btn btn-sm btn-outline-secondary",
            pagination: "d-flex align-items-center gap-3 my-3",
            small: "small", small_muted: "small text-body-secondary"
          }
        }.freeze

        # ---------------------------------------------------------------- step 0
        # Refuse rather than generate something that cannot work.
        def check_models
          return if models.any?

          raise Thor::Error, <<~TEXT
            Name the models whose history may be read:

              rails generate audit_log:views:activity Order Product Customer

            They become ActivityController::VIEWABLE, an allowlist checked BEFORE
            constantize. That order matters: /#{options[:path]}/User/1 is a URL
            anyone can type, and a page that renders audit diffs is where
            constantizing a parameter stops being merely untidy.
          TEXT
        end

        # ---------------------------------------------------------------- step 1
        def create_concern
          once "record_activity.rb.tt", "app/controllers/concerns/record_activity.rb"
        end

        # ---------------------------------------------------------------- step 2
        # The ONE file a second run does change, and only one line of it: adding a
        # model later is adding it to the allowlist.
        def create_controller
          path = "app/controllers/activity_controller.rb"
          return once("activity_controller.rb.tt", path) unless regenerating?(path)

          listed  = read(path)[/VIEWABLE\s*=\s*%w\[([^\]]*)\]/, 1].to_s.split
          missing = viewable - listed

          if listed.empty?
            manual("could not read VIEWABLE in #{path}",
                   %(VIEWABLE = %w[#{viewable.join(" ")}].freeze))
          elsif missing.empty?
            skip("#{path} already lists #{viewable.join(", ")}")
          else
            gsub_file path, /VIEWABLE\s*=\s*%w\[[^\]]*\]/,
                      "VIEWABLE = %w[#{(listed + missing).join(" ")}]", verbose: false
            @added = missing
            say_status :update, "#{path} — added #{missing.join(", ")} to VIEWABLE", :green
          end
        end

        # ---------------------------------------------------------------- step 3
        def create_helper
          once "activity_helper.rb.tt", "app/helpers/activity_helper.rb"
        end

        # ---------------------------------------------------------------- step 4
        def create_views
          return if options[:skip_views]

          once "views/activity/show.html.erb.tt", "app/views/activity/show.html.erb"
          once "views/shared/_activity_feed.html.erb.tt",
               "app/views/shared/_activity_feed.html.erb"
          once "views/shared/_activity_section.html.erb.tt",
               "app/views/shared/_activity_section.html.erb"
        end

        # ---------------------------------------------------------------- step 5
        # A separate locale file, never an edit to config/locales/en.yml: nothing
        # generated should be able to clobber a key of yours.
        def create_locale
          return if options[:skip_locale]

          once "activity.en.yml.tt", "config/locales/audit_log_activity.en.yml"
        end

        # ---------------------------------------------------------------- step 6
        # Plain CSS, because the alternative is generating markup that renders as
        # an unstyled list and looks broken. It is yours to delete.
        def create_stylesheet
          return if options[:skip_css]
          # tailwind and bootstrap carry their own; the markup already names their
          # classes, so a stylesheet here would only be something to un-install.
          return unless options[:css] == "plain"

          dir = "app/assets/stylesheets"
          unless File.directory?(File.join(destination_root, dir))
            return manual("no #{dir}, so no stylesheet was written",
                          nil,
                          "The markup carries semantic class names; style it however you build CSS.")
          end

          once "activity.css.tt", "#{dir}/audit_log_activity.css"
          verify("If you use Sprockets, require audit_log_activity.css from your manifest.",
                 "Propshaft and cssbundling pick it up on their own; Sprockets does not.")
        end

        # ---------------------------------------------------------------- step 7
        def add_route
          return if options[:skip_routes]

          line = %(get "#{options[:path]}/:record_type/:record_id", ) +
                 %(to: "activity#show", as: :activity, constraints: { record_id: /\\d+/ })

          if !File.exist?(File.join(destination_root, "config/routes.rb"))
            manual("config/routes.rb not found", line)
          elsif File.read(File.join(destination_root, "config/routes.rb")).include?("activity#show")
            skip("config/routes.rb already routes activity#show")
          else
            route line
          end
        end

        # ---------------------------------------------------------------- step 8
        # The show-page widget needs the concern in scope. Injected the same way
        # the install generator injects ControllerContext, and reported honestly
        # when it cannot be.
        def include_concern
          app = "app/controllers/application_controller.rb"
          path = File.join(destination_root, app)

          if !File.exist?(path)
            manual("#{app} not found", "include RecordActivity")
          elsif File.read(path).include?("RecordActivity")
            skip("#{app} already includes RecordActivity")
          else
            inject_into_class app, "ApplicationController", "  include RecordActivity\n"
          end
        end

        # ---------------------------------------------------------------- step 9
        # Wire each model named in THIS invocation into its own show page.
        #
        # Runs on every invocation, including the second one -- which is the point:
        # `rails g audit_log:views:activity Product` should add Product to the allowlist
        # AND put the feed on products/show, without touching anything Order's
        # already-edited files.
        #
        # It attempts the edit and REPORTS HONESTLY when it cannot make it. A
        # generator that half-integrates a show page and says "done" leaves a page
        # that renders nothing, which reads as the audit log having no data.
        def integrate_show_pages
          return if options[:skip_show_pages]

          viewable.each { |model| integrate_show_page(model) }
        end

        # ---------------------------------------------------------------- report
        def report
          say ""
          return report_added_model if @existing

          say "  Activity history generated.", :green
          say ""
          say "  IT DENIES EVERYONE UNTIL YOU EDIT ONE METHOD:", :red
          say ""
          say "    app/controllers/concerns/record_activity.rb", :red
          say "    #audit_activity_visible?  ->  currently `false`", :red
          say ""
          say "  That default is deliberate. AuditLog::Timeline exposes previous values"
          say "  of every audited column and the other records each action touched --"
          say "  which on a shared action can be another customer's row. Defaulting to"
          say "  visible would publish all of it to every signed-in user of an app whose"
          say "  roles this gem cannot see, and nothing would report it."
          say ""

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

          verifications.each do |what, why|
            say "  * #{what}", :yellow
            why.to_s.each_line { |l| say "    #{l.chomp}" } if why
            say ""
          end

          say_show_pages
          say "  Links to other records need config.record_url in your initializer;"
          say "  without it the labels render unlinked, ids intact."
          say ""
        end

        private

        # A second run: the files are the host's now, so only the allowlist moved.
        def report_added_model
          if @added
            say "  #{@added.join(", ")} added to ActivityController::VIEWABLE.", :green
          else
            say "  Nothing to do — everything you asked for is already there.", :green
          end
          say ""
          say "  Your generated files were left alone. They are yours: an edited"
          say "  authorization rule, a restyled view or a translated sentence is not"
          say "  something a generator should quietly reverse."
          say ""
          say_show_pages
          say "  To re-baseline every file against this version of the gem's templates,"
          say "  re-run with --force. It overwrites your edits, so diff afterwards."
          say ""
        end

        # Named per model, because "add it to your show page" is not an instruction
        # anybody can follow without knowing which file and which ivar.
        def say_show_pages
          return if options[:skip_show_pages]

          say "  Show pages:", :green
          viewable.each do |model|
            var = model.underscore
            say ""
            say "  #{model}  ->  app/views/#{var.pluralize}/show.html.erb"
            say "            #{" " * model.length}app/controllers/#{var.pluralize}_controller.rb#show"
            say ""
            say "    @activities, @more_activity = recent_activity(@#{var})"
            say ""
            say "    <%= render \"shared/activity_section\", record: @#{var},"
            say "          activities: @activities, more: @more_activity %>"
          end
          say ""
          say "  Anything above marked `inject` or `append` is already done."
          say ""
        end

        def viewable = models.map { |m| m.to_s.camelize }

        # Best-effort, one model. Every branch either edits or explains.
        def integrate_show_page(model)
          var        = model.underscore
          controller = "app/controllers/#{var.pluralize}_controller.rb"
          view       = "app/views/#{var.pluralize}/show.html.erb"

          render_line = <<~ERB
            <%= render "shared/activity_section", record: @#{var},
                  activities: @activities, more: @more_activity %>
          ERB
          load_line = "@activities, @more_activity = recent_activity(@#{var})"

          # A namespaced model has no guessable show page, and guessing wrong here
          # means editing somebody else's file.
          if model.include?("::")
            return show_page_manual(model, load_line, render_line)
          end

          integrate_show_controller(model, controller, var, load_line)
          integrate_show_view(model, view, render_line)
        end

        def integrate_show_controller(model, path, var, line)
          if !file_exists?(path)
            manual("#{path} not found, so #{model}'s show action was not wired up", line)
          elsif read(path).include?("recent_activity")
            skip("#{path} already calls recent_activity")
          elsif !read(path).match?(/^\s*def show\s*$/)
            manual("could not find `def show` in #{path}", line)
          elsif !read(path).match?(/@#{var}\b/)
            # The ivar is the one thing that cannot be inferred. `set_#{var}` in a
            # before_action, a decorator, a different name -- all plausible, and a
            # wrong guess produces a show page that renders an empty feed.
            manual("#{path} never mentions @#{var}, so the ivar could not be inferred", line)
          else
            inject_into_file path, "    #{line}\n", after: /^\s*def show\s*\n/, verbose: false
            say_status :inject, "#{path} — loads #{model} activity in #show", :green
          end
        end

        def integrate_show_view(model, path, block)
          if !file_exists?(path)
            manual("#{path} not found, so the feed was not added to #{model}'s page", block.strip)
          elsif read(path).include?("shared/activity_section")
            skip("#{path} already renders the activity section")
          else
            append_to_file path, "\n#{block}", verbose: false
            say_status :append, "#{path} — renders the activity feed", :green
          end
        end

        def show_page_manual(model, load_line, render_line)
          manual("#{model} is namespaced, so its show page could not be located",
                 nil,
                 "In its show action:  #{load_line}\nIn its show view:\n#{render_line}")
        end

        def read(path) = File.read(File.join(destination_root, path))
        def file_exists?(path) = File.exist?(File.join(destination_root, path))

        # WHAT IS GENERATED BELONGS TO THE HOST THE MOMENT IT LANDS. A second run
        # -- which is how you add a model six months later -- must not rewrite an
        # edited authorization rule, a restyled view, or a translated sentence.
        # Without this, the run either overwrites them (--force) or blocks on
        # Thor's interactive overwrite prompt, and the first is the dangerous one.
        #
        # --force still overwrites, for deliberately re-baselining against a newer
        # version of the gem's templates. That is a decision, not a default.
        def regenerating?(path) = file_exists?(path) && !options[:force]

        def once(source, path)
          return template(source, path) unless regenerating?(path)

          @existing = true
          say_status :yours, "#{path} — left alone", :blue
        end

        # Resolved at GENERATE time. The generated view holds plain strings, so
        # nothing at runtime depends on this generator or on the gem.
        def css(slot) = CLASSES.fetch(options[:css]).fetch(slot)

        def notes         = @notes ||= []
        def verifications = @verifications ||= []

        def manual(what, line = nil, why = nil)
          notes << [what, line, why]
          say_status :manual, what, :yellow
        end

        def verify(what, why = nil)
          verifications << [what, why]
        end

        def skip(what)
          say_status :skip, what, :blue
        end
      end
    end
  end
end
