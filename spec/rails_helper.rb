# frozen_string_literal: true

require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

Rails.root.glob("../support/**/*.rb").sort.each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include AuditContextHelpers
  config.include QueryCounting
  config.include ActiveJob::TestHelper

  # No :job around-hook here, unlike the reference app. That hook exists there to
  # swap Solid Queue out for the ActiveJob test adapter for the duration of an
  # example, because that app deliberately runs the real adapter in test. This
  # app configures the test adapter outright, so the `:job` tag is only a label.

  # Current is reset by the Rails executor in a real request or job; specs have
  # to do it themselves or one example's actor leaks into the next.
  config.before { AuditLog::Current.reset }
end
