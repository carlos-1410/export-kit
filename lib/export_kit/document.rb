# frozen_string_literal: true

module ExportKit
  # Format-neutral input for export renderers. A source adapter describes the document and
  # streams rows; renderers know nothing about Active Record or the domain that produced them.
  class Document
    KEY_FORMAT = /\A[a-z][a-z0-9_]{0,63}\z/
    IDENTIFIER_FORMAT = /\A[a-z][a-z0-9_]{2,63}\z/

    attr_reader :identifier, :metadata, :schema_version, :sections, :title

    def self.string(value) = value.to_s.dup.freeze

    def self.normalize_metadata(value, depth = 0)
      raise ArgumentError, "metadata nesting exceeds limit" if depth > 100

      case value
      when Hash then normalize_hash(value, depth)
      when Array then value.map { normalize_metadata(it, depth + 1) }.freeze
      when String then value.dup.freeze
      when Integer, Float, TrueClass, FalseClass, NilClass then value
      else raise ArgumentError, "unsupported metadata value"
      end
    end

    def self.normalize_hash(value, depth)
      keys = value.keys.map(&:to_s)
      raise ArgumentError, "duplicate metadata keys" unless keys.uniq == keys

      value.to_h { |key, item| [string(key), normalize_metadata(item, depth + 1)] }.freeze
    end

    def self.validate_metadata!(metadata, reserved)
      raise ArgumentError, "metadata must be a hash" unless metadata.is_a?(Hash)
      raise ArgumentError, "reserved metadata key" if metadata.keys.intersect?(reserved)
    end

    # One logical group in a document. Metadata is copied into every format manifest.
    class Section
      attr_reader :description, :key, :label, :metadata, :record_sets

      def initialize(key:, label:, description:, metadata:, record_sets:)
        @key = Document.string(key)
        @label = Document.string(label)
        @description = Document.string(description)
        @metadata = Document.normalize_metadata(metadata)
        @record_sets = Array(record_sets).dup.freeze
        validate!
      end

      private

      def validate!
        Document.validate_metadata!(metadata, %w(category label description record_sets count))
        raise ArgumentError, "invalid export section key" unless key.match?(KEY_FORMAT)
        raise ArgumentError, "export section label is required" if label.strip.empty?

        validate_record_sets!
      end

      def validate_record_sets!
        raise ArgumentError, "invalid record sets" unless record_sets.all?(RecordSet)
        return if record_sets.map(&:name).uniq.size == record_sets.size

        raise ArgumentError, "export record-set names must be unique"
      end
    end

    # A named table with an explicit column order and a callback that yields one Hash per row.
    class RecordSet
      attr_reader :column_labels, :columns, :name

      def initialize(name:, columns:, row_source:, column_labels: {})
        @name = Document.string(name)
        @columns = Array(columns).map { Document.string(it) }.freeze
        @column_labels = @columns.to_h { [it, it] }.merge(
          column_labels.to_h { |key, value| [Document.string(key), Document.string(value)] }
        ).freeze
        @row_source = row_source
        validate!
      end

      def headers
        columns.map { column_labels.fetch(it) }
      end

      def each_row(&)
        row_source.call(&)
      end

      private

      attr_reader :row_source

      def validate!
        validate_name!
        validate_columns!
        validate_labels!
        validate_row_source!
      end

      def validate_name!
        raise ArgumentError, "invalid export record-set name" unless name.match?(KEY_FORMAT)
      end

      def validate_columns!
        raise ArgumentError, "export columns must be unique" unless columns.uniq.size == columns.size
      end

      def validate_labels!
        raise ArgumentError, "export column labels must match columns" unless column_labels.keys == columns
        raise ArgumentError, "export column labels must be unique" unless headers.uniq.size == headers.size
        raise ArgumentError, "export column labels must be present" if headers.any? { it.to_s.strip.empty? }
      end

      def validate_row_source!
        raise ArgumentError, "export row source must be callable" unless row_source.respond_to?(:call)
      end
    end

    def initialize(identifier:, schema_version:, title:, metadata:, sections:)
      @identifier = Document.string(identifier)
      @schema_version = Integer(schema_version)
      @title = Document.string(title)
      @metadata = Document.normalize_metadata(metadata)
      @sections = Array(sections).dup.freeze
      validate!
    end

    def envelope(manifest)
      { "format" => identifier, "schema_version" => schema_version, **metadata, "manifest" => manifest }
    end

    private

    def validate!
      Document.validate_metadata!(metadata, %w(format schema_version manifest data))
      validate_identifier!
      validate_schema_version!
      validate_title!
      validate_sections!
    end

    def validate_identifier!
      raise ArgumentError, "invalid export document identifier" unless identifier.match?(IDENTIFIER_FORMAT)
    end

    def validate_schema_version!
      raise ArgumentError, "invalid export schema version" unless schema_version.positive?
    end

    def validate_title!
      raise ArgumentError, "export document title is required" if title.strip.empty?
    end

    def validate_sections!
      unless sections.all?(Section)
        raise ArgumentError, "export document sections must be ExportKit::Document::Section instances"
      end
      return if sections.map(&:key).uniq.size == sections.size

      raise ArgumentError, "export document needs unique sections"
    end
  end
end
