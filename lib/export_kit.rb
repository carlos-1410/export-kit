# frozen_string_literal: true

require "json"
require "csv"
require "digest"
require "tempfile"
require "export_kit/result"
require "export_kit/document"
require "export_kit/table"
require "export_kit/renderers/base"
require "export_kit/output"
require "export_kit/renderers/json"
require "export_kit/renderers/csv_archive"
require "export_kit/renderers/pdf"
require "export_kit/format_registry"
require "export_kit/validate_artifact"
require "export_kit/artifact"
require "export_kit/render"

module ExportKit
  def self.render(data, **args) = Render.new(data:, **args).call

  def self.validate(artifact, failure_code: ValidateArtifact::INVALID)
    ValidateArtifact.call(built: artifact, failure_code:)
  end
end
