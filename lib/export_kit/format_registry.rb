# frozen_string_literal: true

module ExportKit
  module FormatRegistry
    Definition = Data.define(:key, :extension, :content_type)
    DEFINITIONS = [
      Definition.new(key: "json", extension: "json", content_type: "application/json"),
      Definition.new(key: "csv", extension: "csv", content_type: "text/csv"),
      Definition.new(key: "csv_zip", extension: "zip", content_type: "application/zip"),
      Definition.new(key: "pdf", extension: "pdf", content_type: "application/pdf")
    ].to_h { [it.key, it] }.freeze

    def self.find(key) = DEFINITIONS[key.to_s]
  end
end
