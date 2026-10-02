# frozen_string_literal: true

module ExportKit
  class Table < Document::RecordSet
    def initialize(columns:, rows:, labels: {})
      source = rows.respond_to?(:call) ? rows : ->(&emit) { rows.each(&emit) }
      super(name: "rows", columns:, column_labels: labels, row_source: source)
    end

    def each_row
      index = 0
      super do |row|
        index += 1
        yield normalize(row)
      end
    rescue Renderers::InvalidDocument => e
      raise e.at(record_set: name, row: index)
    end

    private

    def normalize(row)
      validate_keys!(row)
      validate_row_columns!(row.keys.map(&:to_s))
      normalized = row.transform_keys(&:to_s)
      columns.to_h { [it, normalized.fetch(it)] }
    end

    def validate_row_columns!(keys)
      return if keys.uniq == keys && keys.sort == columns.sort

      raise Renderers::InvalidDocument.new(error_details: { column: (columns - keys).first })
    end

    def validate_keys!(row)
      return if row.is_a?(Hash) && row.keys.all? { it.is_a?(String) || it.is_a?(Symbol) }

      raise Renderers::InvalidDocument
    end
  end
end
