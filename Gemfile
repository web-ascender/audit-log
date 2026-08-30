# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# CI pins a Rails version here so the `rails ~> 8.0` the gemspec claims is
# actually exercised at BOTH ends, rather than only at whatever the resolver
# happens to pick. Same argument as the Ruby 3.3 leg: a floor nothing runs
# against is a guess, and this one went unrun until the workflow grew a Rails
# 8.0 leg -- Rails 8.0 has no `Rails.event`, so AuditLog.notify's fallback was
# the only path an adopter on the floor would ever take and the only one that
# nothing exercised.
#
# EMPTY is treated as unset, not as a constraint. The workflow passes "" for the
# unpinned leg, and "" is truthy in Ruby -- `gem "rails", ""` is an unsatisfiable
# requirement, so testing only `if ENV[...]` breaks the leg it was meant to leave
# alone. Unset locally, so development resolves normally.
rails_version = ENV["RAILS_VERSION"].to_s
gem "rails", rails_version unless rails_version.empty?

# Driving the dummy app in spec/. `pg` is deliberately NOT a gemspec dependency:
# the host application picks its own build, and on Ruby 4.0 / arm64-darwin the
# precompiled 1.6.3 binary segfaults inside forked worker processes.
gem "pg", "~> 1.1", force_ruby_platform: true
gem "puma", ">= 5.0"

group :development, :test do
  gem "rspec-rails", "~> 8.0"
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
end
