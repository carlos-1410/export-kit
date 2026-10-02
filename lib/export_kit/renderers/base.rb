# frozen_string_literal: true

module ExportKit
  module Renderers
    class TooLarge < StandardError; end

    class InvalidDocument < StandardError
      attr_reader :error_details

      def initialize(message = "invalid export data", error_details: {})
        super(message)
        @error_details = Result.failure(:invalid, error_details:).error_details
      end

      def at(**details)
        self.class.new(error_details: details.merge(error_details))
      end
    end

    # Shared validation for every renderer: rows must match their declared columns and contain
    # only format-neutral scalar values (or arrays of scalars).
    class Base
      SCALARS = [String, Integer, Float, TrueClass, FalseClass, NilClass].freeze

      def self.validate_row!(record_set, row)
        column = invalid_column(record_set, row)
        valid = row.is_a?(Hash) && row.keys == record_set.columns && row.values.all? { plain?(it) }
        return if valid

        raise InvalidDocument.new(error_details: { record_set: record_set.name, column: })
      end

      def self.invalid_column(record_set, row)
        return unless row.is_a?(Hash)

        record_set.columns.find { !row.key?(it) || !plain?(row[it]) }
      end

      def self.plain?(value)
        return value.all? { scalar?(it) } if value.is_a?(Array)

        scalar?(value)
      end

      def self.scalar?(value)
        return value.finite? if value.is_a?(Float)
        return valid_string?(value) if value.is_a?(String)

        SCALARS.any? { value.is_a?(it) }
      end

      def self.valid_string?(value)
        value.encode(Encoding::UTF_8).valid_encoding?
      rescue EncodingError
        false
      end

      def render(document:, output:, max_bytes:)
        raise NotImplementedError
      end

      private

      def each_row(record_set)
        index = 0
        record_set.each_row do |row|
          index += 1
          self.class.validate_row!(record_set, row)

          yield row
        end
      rescue InvalidDocument => e
        raise e.at(record_set: record_set.name, row: index)
      rescue JSON::GeneratorError, EncodingError
        raise InvalidDocument.new(error_details: { record_set: record_set.name, row: index })
      end

      def manifest_entry(section, counts)
        {
          "category" => section.key,
          "label" => section.label,
          "description" => section.description,
          **section.metadata,
          "record_sets" => counts,
          "count" => counts.values.sum
        }
      end

      def ensure_size!(io, max_bytes)
        raise TooLarge if io.size > max_bytes
      end
    end
  end
end
