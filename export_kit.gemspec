# frozen_string_literal: true

require_relative "lib/export_kit/version"

Gem::Specification.new do |spec|
  spec.name = "export_kit"
  spec.version = ExportKit::VERSION
  spec.authors = ["Łukasz Kerl"]

  spec.summary = "Portable, size-bounded JSON, CSV and PDF exports"
  spec.description = "Builds streamed, size-bounded export artifacts with explicit schemas, " \
                     "safe CSV cells, structural validation and an optional Active Record adapter."
  spec.homepage = "https://github.com/carlos-1410/export-kit"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{spec.version}"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/v#{spec.version}/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "README.pl.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "csv", ">= 3.3.6", "< 4"
  spec.add_dependency "json", ">= 2.21.2", "< 4"
  spec.add_dependency "prawn", "~> 2.5"
  spec.add_dependency "rubyzip", "~> 3.6"
end
