# frozen_string_literal: true

require "rake/testtask"
require "rubocop/rake_task"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "spec" << "lib"
  t.test_files = FileList["spec/**/*_spec.rb"].exclude("spec/fixtures/**/*")
end

RuboCop::RakeTask.new(:lint)

task default: %i[test lint]
