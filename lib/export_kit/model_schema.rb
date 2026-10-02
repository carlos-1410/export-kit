# frozen_string_literal: true

module ExportKit
  # Lets an application model explicitly describe the columns available to any export.
  # Completeness is checked only when the application calls validate_export_schema!.
  module ModelSchema
    extend ActiveSupport::Concern

    included do
      class_attribute :defined_export_schema, instance_writer: false, default: nil
    end

    class_methods do
      def export_schema(&definition)
        return defined_export_schema unless definition

        raise ArgumentError, "Export schema already defined for #{name}" if defined_export_schema

        self.defined_export_schema = DefinitionBuilder.new.tap { it.instance_eval(&definition) }.build
      end

      def validate_export_schema!
        schema = export_schema
        raise ArgumentError, "export schema is missing" unless schema

        classified = schema.allowed + schema.denied.keys
        raise ArgumentError, "export schema does not classify every column" unless classified.sort == column_names.sort

        schema
      end
    end

    Definition = Data.define(:allowed, :denied, :formatters) do
      alias_method :export, :allowed
      alias_method :omit, :denied
    end

    class DefinitionBuilder
      def initialize
        @allowed = []
        @denied = {}
        @formatters = {}
      end

      def allow(*declarations)
        each_field_declaration(declarations) do |key, formatter|
          key = key.to_s
          allowed << key
          formatters[key] = formatter if formatter
        end
      end

      def timestamps
        allow :created_at, :updated_at
      end

      def omit(*columns, because:)
        raise ArgumentError, "omission reason is required" if because.to_s.strip.empty?
        raise ArgumentError, "omitted fields must be unique" if denied.keys.intersect?(columns.map(&:to_s))

        columns.each { |column| denied[column.to_s] = because.to_s }
      end

      alias deny omit

      def build
        validate!

        Definition.new(allowed: allowed.freeze, denied: denied.freeze, formatters: formatters.freeze).freeze
      end

      private

      attr_reader :allowed, :denied, :formatters

      def each_field_declaration(declarations)
        items = declarations.one? && declarations.first.is_a?(Array) ? declarations.first.dup : declarations.dup
        until items.empty?
          key = items.shift

          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError, "An export field must be a String or Symbol"
          end

          yield key, (items.shift if items.first.respond_to?(:call))
        end
      end

      def validate!
        duplicates = allowed & denied.keys
        raise ArgumentError, "Fields cannot be both exported and omitted: #{duplicates.join(", ")}" if duplicates.any?
        raise ArgumentError, "Export fields must be unique" unless allowed.uniq == allowed
      end
    end
  end
end
