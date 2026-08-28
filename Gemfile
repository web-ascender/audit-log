# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Driving the dummy app in spec/. `pg` is deliberately NOT a gemspec dependency:
# the host application picks its own build, and on Ruby 4.0 / arm64-darwin the
# precompiled 1.6.3 binary segfaults inside forked worker processes.
gem "pg", "~> 1.1", force_ruby_platform: true
gem "puma", ">= 5.0"

group :development, :test do
  gem "rspec-rails", "~> 8.0"
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
end
