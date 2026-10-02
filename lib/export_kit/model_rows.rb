# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

module ExportKit
  class ModelRows
    def initialize(record_set:, input:, batch_size:)
      @record_set = record_set
      @input = input
      @batch_size = batch_size
      raise ArgumentError, "batch_size must be positive" unless batch_size.is_a?(Integer) && batch_size.positive?
    end

    def each
      index = 0
      batches do |rows|
        rows.each do |row|
          index += 1
          yield present(row.drop(1))
        end
      end
    rescue Renderers::InvalidDocument => e
      raise e.at(record_set: record_set.name, row: index)
    end

    private

    attr_reader :batch_size, :input, :record_set

    def batches
      relation = record_set.scope.call(input)
      validate_relation!(relation)
      remaining = relation.limit_value
      cursor = nil
      while remaining != 0 && (rows = read_batch(cursor, remaining)).any?
        yield rows
        cursor = rows.last.first
        remaining -= rows.size if remaining
      end
    end

    def read_batch(cursor, remaining)
      limit = remaining ? [remaining, batch_size].min : batch_size
      record_set.page(input, after: cursor, limit:).pluck(*selections)
    end

    def validate_relation!(relation)
      unless valid_relation?(relation)
        raise ArgumentError, "export requires an unordered, ungrouped relation without offset or distinct"
      end
      return unless record_set.model.primary_key.is_a?(Array) || !record_set.model.primary_key

      raise ArgumentError, "export requires a single primary key"
    end

    def valid_relation?(relation)
      relation.is_a?(ActiveRecord::Relation) && relation.klass == record_set.model &&
        !relation.offset_value && relation.group_values.empty? &&
        !relation.distinct_value && relation.order_values.empty?
    end

    def selections
      [record_set.model.arel_table[record_set.model.primary_key], *record_set.selections(input)]
    end

    def present(values)
      row = record_set.output_keys.zip(values).to_h do |key, value|
        [key, scalar_field(key, value)]
      end
      record_set.time_of_day_fields.each do |key|
        value = values[record_set.output_keys.index(key)]
        row[key] = value.strftime("%H:%M:%S") if value
      end
      record_set.present(row, input:)
    end

    def scalar_field(key, value)
      scalar(value)
    rescue Renderers::InvalidDocument => e
      raise e.at(column: key)
    end

    def scalar(value)
      case value
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
      when Date then value.iso8601
      when BigDecimal then value.to_s("F")
      when Array then value.map { scalar(it) }
      when *Renderers::Base::SCALARS then value
      else raise Renderers::InvalidDocument, "unsupported model value"
      end
    end
  end
end
