# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "export_kit"
  spec.version = "0.1.0"
  spec.summary = "Portable, bounded exports with optional Active Record adapters"
  spec.authors = ["Koncertowo contributors"]
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 3.4"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "*.gemspec", "README.md"] }
  spec.require_paths = ["lib"]
  spec.metadata["allowed_push_host"] = "https://publication-not-authorized.invalid"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.add_dependency "csv", ">= 3.3.6", "< 4"
  spec.add_dependency "json", ">= 2.21.2", "< 3"
  spec.add_dependency "prawn", "~> 2.5"
  spec.add_dependency "rubyzip", "~> 3.6"
end
