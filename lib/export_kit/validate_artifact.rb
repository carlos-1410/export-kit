# frozen_string_literal: true

require "csv"
require "digest"
require "zip"

module ExportKit
  # Generic verification of a rendered artifact against the Document that produced it. A concrete
  # workflow may check a few domain identifiers before calling this class, but never reimplements
  # digest, manifest or JSON/CSV/PDF validation.
  class ValidateArtifact
    INVALID = :export_artifact_invalid
    PLAIN_VALUES = [String, Integer, Float, TrueClass, FalseClass, NilClass].freeze

    def self.call(**args) = new(**args).call

    def initialize(built:, failure_code: INVALID)
      @built = built
      @failure_code = failure_code
    end

    def call
      valid = digest_matches? && valid_contents?
      valid ? success(built) : failure(failure_code)
    rescue JSON::ParserError, CSV::MalformedCSVError, Zip::Error, EncodingError, Errno::ENOENT, IOError
      failure(failure_code)
    end

    private

    attr_reader :built, :failure_code

    def document = built.document

    def success(value) = Result.success(value)
    def failure(code) = Result.failure(code)

    def digest_matches?
      built.file.path && File.size(built.file.path) == built.byte_size &&
        Digest::SHA256.file(built.file.path).hexdigest == built.sha256
    end

    def valid_contents?
      return valid_simple_contents? unless document.is_a?(Document)

      valid_artifact_metadata? && valid_manifest? && valid_format?
    end

    def valid_simple_contents?
      case built.format
      when "json" then valid_simple_json?
      when "csv" then valid_simple_csv?
      when "pdf" then valid_pdf?
      else false
      end
    end

    def valid_simple_json?
      value = JSON.parse(File.read(built.file.path))
      !document.is_a?(Table) || (value.is_a?(Array) && value.all? { valid_record?(it, document) })
    end

    def valid_simple_csv?
      return false unless document.is_a?(Table)

      table = CSV.parse(File.read(built.file.path), headers: true)
      table.headers == expected_csv_headers(document) && table.all? { it.size == document.columns.size }
    end

    def valid_artifact_metadata?
      definition = ExportKit::FormatRegistry.find(built.format == "csv" ? "csv_zip" : built.format)
      return false unless definition

      actual = [built.identifier, built.schema_version, built.content_type, built.extension, built.metadata]
      expected = [document.identifier, document.schema_version, definition.content_type, definition.extension,
                  document.metadata]
      actual == expected
    end

    def valid_manifest?
      return false unless built.manifest.is_a?(Array) && built.manifest.size == document.sections.size

      document.sections.zip(built.manifest).all? { |section, entry| valid_manifest_entry?(section, entry) }
    end

    def valid_manifest_entry?(section, entry)
      return false unless entry.is_a?(Hash)

      counts = entry["record_sets"]
      valid_manifest_counts?(section, counts) && entry == expected_manifest_entry(section, counts)
    end

    def expected_manifest_entry(section, counts)
      {
        "category" => section.key, "label" => section.label, "description" => section.description,
        **section.metadata, "record_sets" => counts, "count" => counts&.values&.sum
      }
    end

    def valid_manifest_counts?(section, counts)
      counts.is_a?(Hash) && counts.keys == section.record_sets.map(&:name) &&
        counts.values.all? { it.is_a?(Integer) && it >= 0 }
    end

    def valid_format?
      case built.format
      when "json" then valid_json?
      when "csv_zip", "csv" then valid_csv_archive?
      when "pdf" then valid_pdf?
      else false
      end
    end

    def valid_json?
      document = JSON.parse(File.read(built.file.path))
      valid_json_shape?(document) && valid_json_envelope?(document) &&
        document["manifest"] == built.manifest && valid_json_data?(document["data"])
    end

    def valid_json_shape?(document)
      expected_keys = (built.metadata.keys + %w(format schema_version manifest data)).sort
      document.is_a?(Hash) && document.keys.sort == expected_keys
    end

    def valid_json_envelope?(document)
      document.except("format", "schema_version", "manifest", "data") == built.metadata &&
        document["format"] == built.identifier && document["schema_version"] == built.schema_version
    end

    def valid_json_data?(data)
      categories = document.sections.map(&:key)
      return false unless data.is_a?(Hash) && data.keys == categories

      built.manifest.all? { |entry| valid_json_category?(data.fetch(entry["category"]), entry) }
    end

    def valid_json_category?(sets, entry)
      record_sets = section(entry.fetch("category")).record_sets
      return false unless sets.is_a?(Hash) && sets.keys == record_sets.map(&:name) && counted?(sets, entry)

      record_sets.all? { |record_set| sets.fetch(record_set.name).all? { valid_record?(it, record_set) } }
    end

    def counted?(sets, entry)
      entry["record_sets"] == sets.transform_values { it.is_a?(Array) ? it.size : -1 } &&
        entry["count"] == entry["record_sets"].values.sum
    end

    def valid_record?(record, record_set)
      record.is_a?(Hash) && record.keys == record_set.columns && record.values.all? { plain?(it) }
    end

    def plain?(value)
      return value.all? { |item| PLAIN_VALUES.any? { item.is_a?(it) } } if value.is_a?(Array)

      PLAIN_VALUES.any? { value.is_a?(it) }
    end

    def valid_csv_archive?
      Zip::File.open(built.file.path) do |archive|
        next false unless valid_csv_entries?(archive)
        next false unless valid_csv_manifest?(csv_entry_contents(archive, "manifest.csv"))

        valid_csv_record_sets?(archive)
      end
    end

    def valid_csv_entries?(archive)
      names = archive.entries.map(&:name)
      names.sort == ["manifest.csv", *expected_csv_files].sort && names.all? { safe_zip_path?(it) }
    end

    def expected_csv_files
      built.manifest.flat_map do |entry|
        entry.fetch("record_sets").filter_map do |record_set, count|
          "data/#{entry.fetch("category")}/#{record_set}.csv" if count.positive?
        end
      end
    end

    def safe_zip_path?(name)
      name == "manifest.csv" || name.match?(%r{\Adata/[a-z][a-z0-9_]*/[a-z][a-z0-9_]*\.csv\z})
    end

    def valid_csv_manifest?(contents)
      rows = CSV.parse(contents, headers: true)
      return false unless rows.headers == ExportKit::Renderers::CsvArchive::MANIFEST_COLUMNS
      return false unless rows.size == expected_csv_manifest_rows

      valid_csv_document_manifest?(rows) && valid_csv_section_manifest?(rows) && valid_csv_record_set_manifest?(rows)
    end

    def expected_csv_manifest_rows
      3 + built.metadata.size + document.sections.sum { 1 + it.record_sets.size }
    end

    def valid_csv_document_manifest?(rows)
      expected = expected_csv_document_metadata
      entries = csv_document_metadata_entries(rows)

      valid_csv_document_entries?(entries, expected) && entries.reduce({}, :merge) == expected
    end

    def expected_csv_document_metadata
      { "format" => built.identifier, "schema_version" => built.schema_version,
        "title" => document.title, **built.metadata }
    end

    def csv_document_metadata_entries(rows)
      rows.filter_map { JSON.parse(it["metadata"]) if it["kind"] == "document" }
    end

    def valid_csv_document_entries?(entries, expected)
      entries.all? { it.is_a?(Hash) && it.one? } && entries.flat_map(&:keys).sort == expected.keys.sort
    end

    def valid_csv_section_manifest?(rows)
      built.manifest.all? do |entry|
        row = sole_manifest_row(rows, "section", entry.fetch("category"))
        row && row["count"].to_i == entry.fetch("count") &&
          JSON.parse(row["metadata"]) == entry.except("category", "label", "description", "record_sets", "count")
      end
    end

    def valid_csv_record_set_manifest?(rows)
      built.manifest.all? do |entry|
        section(entry.fetch("category")).record_sets.all? { valid_csv_record_set_manifest_row?(rows, entry, it) }
      end
    end

    def valid_csv_record_set_manifest_row?(rows, entry, record_set)
      row = sole_manifest_row(rows, "record_set", entry.fetch("category"), record_set.name)
      count = entry.fetch("record_sets").fetch(record_set.name)
      row && row["file"] == expected_csv_file(entry, record_set, count) && row["count"].to_i == count &&
        JSON.parse(row["metadata"]) == expected_csv_record_set_metadata(record_set)
    end

    def expected_csv_file(entry, record_set, count)
      "data/#{entry.fetch("category")}/#{record_set.name}.csv" if count.positive?
    end

    def expected_csv_record_set_metadata(record_set)
      { "columns" => record_set.columns, "headers" => expected_csv_headers(record_set) }
    end

    def sole_manifest_row(rows, kind, section, record_set = nil)
      matches = rows.select do |row|
        row.values_at("kind", "section", "record_set") == [kind, section, record_set]
      end
      matches.first if matches.one?
    end

    def valid_csv_record_sets?(archive)
      built.manifest.all? do |entry|
        section(entry.fetch("category")).record_sets.all? { valid_csv_record_set?(archive, entry, it) }
      end
    end

    def valid_csv_record_set?(archive, entry, record_set)
      count = entry.fetch("record_sets").fetch(record_set.name)
      return count.zero? unless count.positive?

      path = "data/#{entry.fetch("category")}/#{record_set.name}.csv"
      table = CSV.parse(csv_entry_contents(archive, path), headers: true)
      table.headers == expected_csv_headers(record_set) && table.size == count
    end

    def csv_entry_contents(archive, path)
      utf8(archive.find_entry(path).get_input_stream.read)
    end

    def expected_csv_headers(record_set)
      record_set.headers.map { Renderers::CsvArchive.csv_value(it) }
    end

    def section(key)
      document.sections.find { it.key == key }
    end

    def valid_pdf?
      File.open(built.file.path, "rb") do |file|
        file.read(8)&.start_with?("%PDF-") && begin
          file.seek(-[file.size, 1024].min, IO::SEEK_END)
          file.read.include?("%%EOF")
        end
      end
    end

    def utf8(contents)
      encoded = contents.force_encoding(Encoding::UTF_8)
      raise EncodingError, "export CSV is not UTF-8" unless encoded.valid_encoding?

      encoded
    end
  end
end
