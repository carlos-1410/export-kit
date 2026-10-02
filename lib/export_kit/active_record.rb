# frozen_string_literal: true

require "export_kit"
require "active_record"
require "export_kit/model_schema"
require "export_kit/model_serializer"
require "export_kit/model_rows"

module ExportKit
  def self.records(scope, fields:, labels: {}, batch_size: 500)
    set = ModelSerializer::RecordSetBuilder.new(
      "rows", model: scope.klass, scope: ->(_) { scope }, fields:, schema: nil
    ).build
    Table.new(columns: set.output_keys, labels:, rows: ->(&emit) { set.each_row(batch_size:, &emit) })
  end
end
