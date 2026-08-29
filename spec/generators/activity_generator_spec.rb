# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "erb"
require "generators/audit_log/activity/activity_generator"

# The activity generator hands a host application a working audit UI it then
# owns. Two things make it worth specs rather than a smoke test:
#
#   * it emits ERB THROUGH ERB. Every runtime tag in a view template has to
#     survive generation escaped, and a mistake there produces a file that either
#     blows up at generate time or renders its own source.
#   * it decides who may read an audit history, and the safe default is the one
#     nobody notices is missing.
RSpec.describe AuditLog::Generators::ActivityGenerator do
  def generate(args, host: {})
    dir = Dir.mktmpdir("audit_log_activity")
    %w[config config/locales app/controllers app/helpers app/assets/stylesheets].each do |d|
      FileUtils.mkdir_p(File.join(dir, d))
    end
    File.write(File.join(dir, "config/routes.rb"), host.fetch(:routes, "Rails.application.routes.draw do\nend\n"))

    Array(host[:models]).each do |m|
      FileUtils.mkdir_p(File.join(dir, "app/views/#{m.underscore.pluralize}"))
      File.write(File.join(dir, "app/controllers/#{m.underscore.pluralize}_controller.rb"), <<~RUBY)
        class #{m.pluralize}Controller < ApplicationController
          before_action :set_#{m.underscore}, only: %i[show]

          def show
          end

          private

          def set_#{m.underscore}
            @#{m.underscore} = #{m}.find(params[:id])
          end
        end
      RUBY
      File.write(File.join(dir, "app/views/#{m.underscore.pluralize}/show.html.erb"),
                 "<h1><%= @#{m.underscore}.name %></h1>\n")
    end
    if host.fetch(:controller, true)
      File.write(File.join(dir, "app/controllers/application_controller.rb"),
                 "class ApplicationController < ActionController::Base\nend\n")
    end

    # Both streams: Thor's own refusals go to stderr, and "it refused" is a
    # property worth asserting rather than a message worth losing.
    output = StringIO.new
    out, err = $stdout, $stderr
    $stdout = $stderr = output
    described_class.start(args, destination_root: dir)
    [dir, output.string]
  ensure
    $stdout, $stderr = out, err
  end

  def read(dir, path) = File.read(File.join(dir, path))
  def exist?(dir, path) = File.exist?(File.join(dir, path))

  after { FileUtils.rm_rf(@dir) if @dir }

  describe "what it produces" do
    it "generates a working set of files and a route" do
      @dir, = generate(%w[Order Product])

      %w[
        app/controllers/concerns/record_activity.rb
        app/controllers/activity_controller.rb
        app/helpers/activity_helper.rb
        app/views/activity/show.html.erb
        app/views/shared/_activity_feed.html.erb
        app/views/shared/_activity_section.html.erb
        config/locales/audit_log_activity.en.yml
      ].each { |f| expect(exist?(@dir, f)).to be(true), "missing #{f}" }

      expect(read(@dir, "config/routes.rb")).to include('to: "activity#show"')
      expect(read(@dir, "app/controllers/application_controller.rb")).to include("include RecordActivity")
    end

    # The generated Ruby has to parse and the generated ERB has to compile. This
    # is the guard for the escaping: a template that leaks a generate-time tag
    # produces a view rendering its own source, which looks like a styling bug.
    it "generates syntactically valid Ruby, ERB and YAML" do
      @dir, = generate(%w[Order])

      Dir.glob("#{@dir}/app/**/*.rb").each do |f|
        expect(system("ruby", "-c", f, out: File::NULL, err: File::NULL)).to be(true), "bad Ruby: #{f}"
      end
      Dir.glob("#{@dir}/app/views/**/*.erb").each do |f|
        expect { ERB.new(File.read(f), trim_mode: "-").src }.not_to raise_error, "bad ERB: #{f}"
      end
      expect { YAML.load_file("#{@dir}/config/locales/audit_log_activity.en.yml") }.not_to raise_error
    end

    # Runtime ERB must arrive as ERB, not as its result.
    it "keeps the views' own ERB intact through generation" do
      @dir, = generate(%w[Order])
      feed = read(@dir, "app/views/shared/_activity_feed.html.erb")

      expect(feed).to include("<% activities.each do |activity| %>")
      expect(feed).to include("<%= activity_sentence(activity) %>")
      expect(feed).not_to include("<%%")          # nothing left double-escaped
    end

    it "names the models it was given as the allowlist" do
      @dir, = generate(%w[Order Product Customer])
      expect(read(@dir, "app/controllers/activity_controller.rb"))
        .to include('VIEWABLE = %w[Order Product Customer].freeze')
    end

    # Thor prints a Thor::Error rather than re-raising, so the property that
    # matters is that it produced NOTHING -- a half-generated activity UI with an
    # empty allowlist would 404 on every record and look like a routing bug.
    it "refuses, and generates nothing, when given no models" do
      @dir, output = generate([])

      expect(output).to match(/Name the models/)
      expect(exist?(@dir, "app/controllers/activity_controller.rb")).to be(false)
      expect(exist?(@dir, "app/views/shared/_activity_feed.html.erb")).to be(false)
      expect(read(@dir, "config/routes.rb")).not_to include("activity#show")
    end
  end

  # THE SAFE DEFAULT. A generated `true` here would publish previous values of
  # every audited column -- and other records touched by the same action -- to
  # every signed-in user of an app whose roles this gem cannot see.
  describe "authorization" do
    it "denies everyone until the host edits one method" do
      @dir, = generate(%w[Order])
      concern = read(@dir, "app/controllers/concerns/record_activity.rb")

      expect(concern).to match(/def audit_activity_visible\?\s*\n\s*false\s*\n\s*end/)
      expect(concern).to include("THE ONE METHOD YOU MUST EDIT")
    end

    it "says so in the report, in red, rather than only in a comment" do
      @dir, output = generate(%w[Order])
      expect(output).to include("DENIES EVERYONE UNTIL YOU EDIT ONE METHOD")
      expect(output).to include("audit_activity_visible?")
    end

    # The section partial asks the same question the controller does, so it has
    # to reach view scope -- without this the widget raises NoMethodError on a
    # private controller method.
    it "exposes the rule to views" do
      @dir, = generate(%w[Order])
      expect(read(@dir, "app/controllers/concerns/record_activity.rb"))
        .to include("helper_method :audit_activity_visible?")
    end

    it "is asked by both the page and the widget, so they cannot disagree" do
      @dir, = generate(%w[Order])
      expect(read(@dir, "app/controllers/activity_controller.rb")).to include("audit_activity_visible?")
      expect(read(@dir, "app/views/shared/_activity_section.html.erb")).to include("audit_activity_visible?")
    end
  end

  describe "--css" do
    it "ships a stylesheet for plain and none for a framework that has its own" do
      @dir, = generate(%w[Order])
      expect(exist?(@dir, "app/assets/stylesheets/audit_log_activity.css")).to be(true)
      FileUtils.rm_rf(@dir)

      %w[tailwind bootstrap].each do |framework|
        @dir, = generate(%W[Order --css=#{framework}])
        expect(exist?(@dir, "app/assets/stylesheets/audit_log_activity.css")).to be(false)
        FileUtils.rm_rf(@dir)
      end
      @dir = nil
    end

    # SAME MARKUP, different class attributes. Only `class=` changes, so a host
    # switching frameworks rewrites strings rather than re-deriving the view.
    it "keeps the structure identical across frameworks" do
      structure = %w[plain tailwind bootstrap].map do |framework|
        dir, = generate(%W[Order --css=#{framework}])
        html = read(dir, "app/views/shared/_activity_feed.html.erb")
        FileUtils.rm_rf(dir)
        html.gsub(/class="[^"]*"/, 'class="X"').gsub(/class: "[^"]*"/, 'class: "X"')
      end

      expect(structure.uniq.size).to eq(1)
    end

    it "emits the framework's own class names" do
      @dir, = generate(%w[Order --css=tailwind])
      expect(read(@dir, "app/helpers/activity_helper.rb")).to include("rounded-lg")
      FileUtils.rm_rf(@dir)

      @dir, = generate(%w[Order --css=bootstrap])
      expect(read(@dir, "app/helpers/activity_helper.rb")).to include("card-body")
    end

    # Whichever framework, a registered summary and a sentence the host composed
    # must not look the same -- one is frozen history, the other is recomputed.
    it "keeps narrated and unnarrated visually distinguishable in every framework" do
      %w[plain tailwind bootstrap].each do |framework|
        dir, = generate(%W[Order --css=#{framework}])
        helper = read(dir, "app/helpers/activity_helper.rb")
        narrated, bare = helper[/narrative\? \? "([^"]*)" : "([^"]*)"/, 1], Regexp.last_match(2)
        FileUtils.rm_rf(dir)

        expect(narrated).not_to eq(bare), "#{framework} renders both kinds identically"
      end
    end
  end

  # ADDING A SECOND MODEL LATER. This is the run that happens six months after
  # the first one, against files the host has since edited, and it is the run
  # most likely to do damage: overwriting an edited authorization rule reopens a
  # history to everyone, and nothing reports it.
  describe "running it again to add another model" do
    def install_then_add(second_args)
      dir, = generate(%w[Order])
      concern = File.join(dir, "app/controllers/concerns/record_activity.rb")
      # The host does the one thing the generator told it to.
      File.write(concern, File.read(concern).sub("    false\n", "    current_user&.staff?\n"))
      # ...and restyles a view, as hosts do.
      view = File.join(dir, "app/views/shared/_activity_feed.html.erb")
      File.write(view, File.read(view) + "\n<%# host tweak %>\n")

      output = begin
        out = StringIO.new
        o, e = $stdout, $stderr
        $stdout = $stderr = out
        described_class.start(second_args, destination_root: dir)
        out.string
      ensure
        $stdout, $stderr = o, e
      end
      [dir, output, concern, view]
    end

    it "adds the model to the allowlist and leaves every file alone" do
      @dir, output, concern, view = install_then_add(%w[Order Product])

      expect(read(@dir, "app/controllers/activity_controller.rb"))
        .to include("VIEWABLE = %w[Order Product]")
      expect(File.read(concern)).to include("current_user&.staff?")
      expect(File.read(concern)).not_to match(/def audit_activity_visible\?\s*\n\s*false/)
      expect(File.read(view)).to include("host tweak")
      expect(output).to include("added to ActivityController::VIEWABLE")
    end

    # Naming only the new model is the natural thing to type, and must not drop
    # the model already there.
    it "keeps models already in the allowlist when only the new one is named" do
      @dir, = install_then_add(%w[Product])
      expect(read(@dir, "app/controllers/activity_controller.rb"))
        .to include("VIEWABLE = %w[Order Product]")
    end

    it "does nothing, loudly, when the model is already listed" do
      @dir, output = install_then_add(%w[Order])
      expect(output).to include("Nothing to do")
      expect(read(@dir, "app/controllers/activity_controller.rb"))
        .to include("VIEWABLE = %w[Order]")
    end

    # The escape hatch stays available, because re-baselining against newer
    # templates is a real thing to want -- it just has to be asked for.
    it "still overwrites when --force is passed" do
      @dir, _, concern = install_then_add(%w[Order Product --force])
      expect(File.read(concern)).to match(/def audit_activity_visible\?\s*\n\s*false/)
    end
  end

  # Wiring the show page is the step a host is most likely to get subtly wrong by
  # hand -- the ivar has to match, and a mismatch renders an empty feed rather
  # than an error, which reads as "the audit log has no data".
  describe "wiring up a model's show page" do
    it "loads the activities in #show and renders the feed in the view" do
      @dir, output = generate(%w[Order], host: { models: %w[Order] })

      expect(read(@dir, "app/controllers/orders_controller.rb"))
        .to match(/def show\n\s*@activities, @more_activity = recent_activity\(@order\)/)
      expect(read(@dir, "app/views/orders/show.html.erb"))
        .to include('render "shared/activity_section", record: @order')
      expect(output).to match(/inject.*orders_controller/)
      expect(output).to match(/append.*orders\/show/)
    end

    # The second invocation wires the NEW model's page while leaving the first
    # model's -- already edited by then -- alone.
    it "wires only the model named in this invocation" do
      dir, = generate(%w[Order], host: { models: %w[Order Product] })
      before = File.read(File.join(dir, "app/views/orders/show.html.erb"))

      out = StringIO.new
      o, e = $stdout, $stderr
      $stdout = $stderr = out
      described_class.start(%w[Product], destination_root: dir)
      $stdout, $stderr = o, e

      @dir = dir
      expect(read(@dir, "app/views/products/show.html.erb")).to include("record: @product")
      expect(File.read(File.join(dir, "app/views/orders/show.html.erb"))).to eq(before)
      expect(out.string).to include("Product added to ActivityController::VIEWABLE")
    end

    it "does not wire the same page twice" do
      dir, = generate(%w[Order], host: { models: %w[Order] })
      out = StringIO.new
      o, e = $stdout, $stderr
      $stdout = $stderr = out
      described_class.start(%w[Order], destination_root: dir)
      $stdout, $stderr = o, e

      @dir = dir
      expect(read(@dir, "app/views/orders/show.html.erb").scan("activity_section").size).to eq(1)
      expect(read(@dir, "app/controllers/orders_controller.rb").scan("recent_activity").size).to eq(1)
    end

    # THE IVAR IS THE ONE THING THAT CANNOT BE INFERRED. Guessing @order when the
    # controller calls it something else produces a page that renders an empty
    # feed and reports nothing, so the generator declines and says the line.
    it "reports rather than guesses when it cannot find the ivar" do
      @dir, output = generate(%w[Order], host: { models: %w[Order] })
      FileUtils.rm_rf(@dir)

      dir = Dir.mktmpdir("audit_log_activity")
      %w[config config/locales app/controllers app/helpers app/assets/stylesheets
         app/views/orders].each { |d| FileUtils.mkdir_p(File.join(dir, d)) }
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      File.write(File.join(dir, "app/controllers/application_controller.rb"),
                 "class ApplicationController < ActionController::Base\nend\n")
      File.write(File.join(dir, "app/controllers/orders_controller.rb"), <<~RUBY)
        class OrdersController < ApplicationController
          def show
            @sales_order = Order.find(params[:id])
          end
        end
      RUBY
      File.write(File.join(dir, "app/views/orders/show.html.erb"), "<h1>x</h1>\n")

      out = StringIO.new
      o, e = $stdout, $stderr
      $stdout = $stderr = out
      described_class.start(%w[Order], destination_root: dir)
      $stdout, $stderr = o, e

      @dir = dir
      expect(read(@dir, "app/controllers/orders_controller.rb")).not_to include("recent_activity")
      expect(out.string).to include("never mentions @order")
      expect(out.string).to include("recent_activity(@order)")
    end

    it "leaves show pages alone with --skip-show-pages" do
      @dir, = generate(%w[Order --skip-show-pages], host: { models: %w[Order] })
      expect(read(@dir, "app/views/orders/show.html.erb")).not_to include("activity_section")
    end
  end

  describe "when the host is not shaped as expected" do
    it "reports a missing ApplicationController instead of claiming success" do
      @dir, output = generate(%w[Order], host: { controller: false })
      expect(output).to include("include RecordActivity")
      expect(output).to match(/manual/i)
    end

    it "does not add a second route when one is already there" do
      routes = %(Rails.application.routes.draw do\n  get "x", to: "activity#show"\nend\n)
      @dir, output = generate(%w[Order], host: { routes: routes })

      expect(read(@dir, "config/routes.rb").scan("activity#show").size).to eq(1)
      expect(output).to match(/skip/i)
    end
  end
end
