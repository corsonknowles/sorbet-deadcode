# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  # benchmark was removed from Ruby's default gems in 4.0; declare it explicitly
  # so the performance spec loads on every Ruby version.
  gem "benchmark"
  gem "minitest", "~> 5.0"
  gem "rake", "~> 13.0"
  gem "rubocop", "~> 1.0", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
  gem "simplecov", "~> 0.22", require: false
  gem "sorbet-static-and-runtime"
end
