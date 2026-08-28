# frozen_string_literal: true

require "rails_helper"

RSpec.describe "job base class" do
  # Inheriting from ApplicationJob is the entire integration. A job that inherits
  # directly from ActiveJob::Base is the one way to lose correlation, so it is
  # worth failing the build over.
  it "has every job inherit from ApplicationJob" do
    Rails.root.glob("app/jobs/**/*.rb").each { |f| require f }

    offenders = ActiveJob::Base.descendants.select do |klass|
      klass.name.present? &&
        klass.superclass == ActiveJob::Base &&
        klass != ApplicationJob &&
        klass.name.start_with?(*%w[Order Nightly Catalog])
    end

    expect(offenders).to be_empty,
      "These jobs skip ApplicationJob and will lose audit correlation: #{offenders.join(', ')}"
  end

  it "defers enqueue until the enclosing transaction commits" do
    # Set on the class, not via config.active_job.enqueue_after_transaction_commit:
    # ActiveJob's railtie explicitly filters that key out of the global config.
    expect(ApplicationJob.enqueue_after_transaction_commit).to be(true)
  end
end
