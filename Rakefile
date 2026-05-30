# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "spec" << "lib"
  t.test_files = FileList["spec/**/*_spec.rb"].exclude("spec/fixtures/**/*")
end

task default: :test
