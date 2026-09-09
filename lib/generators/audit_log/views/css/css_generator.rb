# frozen_string_literal: true

require "rails/generators"

module AuditLog
  module Generators
    module Views
      # `rails generate audit_log:views:css`
      #
      # A starting stylesheet for the auditor UI the engine mounts at /audit,
      # written into the host application COMMENTED OUT.
      #
      # WHY THE ENGINE SHIPS NO CSS. Its screens render inside the HOST's layout
      # -- that is the whole point of `config.parent_controller` -- so any
      # stylesheet the gem loaded would arrive uninvited on a page the host
      # designed, and would have to be fought rather than adopted. The screens
      # therefore carry semantic class names and nothing else, and an application
      # that wants them styled starts from this and owns the result.
      #
      # WHY COMMENTED OUT RATHER THAN JUST GENERATED. A generated stylesheet that
      # is live the moment it lands is the same imposition one step removed: the
      # host discovers it by seeing their audit screens change. Inert, it is a
      # proposal.
      #
      # ONE EXPLAINER, THEN ONE BLOCK COMMENT ROUND THE WHOLE STYLESHEET, so
      # enabling is deleting two lines -- or selecting that block and pressing
      # the editor's toggle-block-comment key. An earlier version wrapped each of
      # the twelve sections separately, which bought selective enabling nobody
      # asked for and made the ordinary case a `sed` incantation. The common
      # gesture wins.
      #
      # THE BLOCK THEREFORE CONTAINS NO COMMENTS AT ALL, which is a constraint on
      # the template rather than a style choice: one comment-closing delimiter
      # inside it would end the block early and leave the rest of the stylesheet
      # live, un-enabled and unannounced. The section map lives in the explainer
      # above it instead. `css_generator_spec` enables the file the documented
      # way and parses the result, so that cannot rot quietly.
      #
      # CREATE-ONCE AND HOST-OWNED, DESIGN §21.3. Never re-generated, never
      # upgraded, and nothing in the gem may learn whether it exists or whether
      # it is current -- that would turn owned code back into managed code.
      class CssGenerator < Rails::Generators::Base
        source_root File.expand_path("templates", __dir__)

        desc <<~DESC
          Write a starter stylesheet for the auditor UI into app/assets/stylesheets.
          It arrives commented out; enabling it is one deletion of the delimiter lines.
        DESC

        class_option :path, type: :string, default: "app/assets/stylesheets",
                            desc: "Directory to write the stylesheet into"
        class_option :mount_path, type: :string, default: "/audit",
                                  desc: "Where the engine is mounted, for the file's header"

        def create_stylesheet
          unless File.directory?(File.join(destination_root, options[:path]))
            @manual = true
            return say_status :manual, "no #{options[:path]}, so nothing was written", :yellow
          end

          if File.exist?(File.join(destination_root, target)) && !options[:force]
            @existing = true
            return say_status :yours, "#{target} — left alone", :blue
          end

          template "audit_log.css.tt", target
        end

        def report
          return if @manual

          say ""
          if @existing
            say "The stylesheet was already there and has not been touched.", :blue
            return
          end

          say "Wrote #{target}, commented out. It changes nothing until you enable it:", :green
          say ""
          say "  delete the bare comment-opening line under the header, and the file's"
          say "  last line -- or select that block and toggle the comment in your editor"
          say ""
          say "then load it the way this app loads stylesheets --", :yellow
          say "  Propshaft   <%= stylesheet_link_tag \"audit_log\" %> in your layout"
          say "  Sprockets   *= require audit_log  in application.css"
          say "  Sass        @import \"audit_log\"; in application.scss"
          say ""
          say "Nothing loads it merely for being present, and the gem never checks.", :yellow
        end

        private

        def target = File.join(options[:path], "audit_log.css")

        # Used by the template's header line. Read at GENERATE time, so the file
        # that lands holds a plain string and depends on nothing.
        def mount_path = options[:mount_path]
      end
    end
  end
end
