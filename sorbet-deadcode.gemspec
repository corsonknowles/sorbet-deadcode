# frozen_string_literal: true

require_relative "lib/sorbet_deadcode/version"

Gem::Specification.new do |spec|
  spec.name = "sorbet-deadcode"
  spec.version = SorbetDeadcode::VERSION
  spec.authors = ["David Corson-Knowles"]
  spec.email = ["david@corsonknowles.com"]

  spec.summary = "Type-aware dead code detection for Ruby using Sorbet's type graph"
  spec.description = <<~DESC
    Unlike name-based tools, sorbet-deadcode uses Sorbet's type information to
    resolve which methods are actually called on which types. This eliminates
    false positives from dynamic dispatch (AASM, delegates, validates, etc.)
    and false negatives from name collisions across unrelated classes.
  DESC
  spec.homepage = "https://github.com/corsonknowles/sorbet-deadcode"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "exe/*", "LICENSE.txt", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["sorbet-deadcode"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 0.28.0"
  spec.add_dependency "sorbet-runtime", ">= 0.5.0"
end
