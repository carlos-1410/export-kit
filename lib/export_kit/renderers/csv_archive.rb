# frozen_string_literal: true

require "csv"
require "tempfile"
require "zip"

module ExportKit
  module Renderers
    # A multi-table document cannot be represented faithfully by one rectangular CSV. This
    # renderer writes one UTF-8 CSV per non-empty record set plus a deterministic manifest.csv.
    class CsvArchive < Base
      MANIFEST_COLUMNS = %w(kind section record_set file count metadata).freeze
      FORMULA_PREFIX = /\A[[:space:]]*[=+\-@]/

      def self.csv_value(value)
        rendered = value.is_a?(Array) ? JSON.generate(value) : value
        rendered.is_a?(String) && rendered.match?(FORMULA_PREFIX) ? "'#{rendered}" : rendered
      end

      def render(document:, output:, max_bytes:)
        manifest = nil
        Zip::OutputStream.write_buffer(output) do |archive|
          bounded = Output.new(io: archive, max_bytes:)
          manifest, files = write_record_sets(document, archive, bounded)
          write_manifest(document, manifest, files, archive, bounded)
        end
        ensure_size!(output, max_bytes)
        manifest
      end

      private

      def write_record_sets(document, archive, bounded)
        state = { files: {} }
        manifest = document.sections.map { write_section(it, archive, bounded, state) }
        [manifest, state.fetch(:files)]
      end

      def write_section(section, archive, bounded, state)
        counts = section.record_sets.to_h do |record_set|
          count, filename = write_record_set(section, record_set, archive, bounded)

          state.fetch(:files)[[section.key, record_set.name]] = filename
          [record_set.name, count]
        end
        manifest_entry(section, counts)
      rescue InvalidDocument => e
        raise e.at(section: section.key)
      end

      def write_record_set(section, record_set, archive, bounded)
        csv = CSV.new(bounded)
        count = 0
        each_row(record_set) do |row|
          start_record_set(archive, csv, section, record_set) if count.zero?
          csv << record_set.columns.map { self.class.csv_value(row.fetch(it)) }
          count += 1
        end
        [count, record_set_filename(section, record_set, count)]
      end

      def start_record_set(archive, csv, section, record_set)
        archive.put_next_entry(record_set_filename(section, record_set, 1))
        csv << record_set.headers.map { self.class.csv_value(it) }
      end

      def record_set_filename(section, record_set, count)
        "data/#{section.key}/#{record_set.name}.csv" if count.positive?
      end

      def write_manifest(document, manifest, files, archive, bounded)
        archive.put_next_entry("manifest.csv")
        csv = CSV.new(bounded)
        csv << MANIFEST_COLUMNS
        write_document_manifest(csv, document)
        document.sections.zip(manifest).each do |section, entry|
          write_section_manifest(csv, section, entry, files)
        end
      end

      def write_document_manifest(csv, document)
        metadata = {
          "format" => document.identifier,
          "schema_version" => document.schema_version,
          "title" => document.title, **document.metadata
        }
        metadata.each { |key, value| csv << ["document", nil, nil, nil, nil, JSON.generate(key => value)] }
      end

      def write_section_manifest(csv, section, entry, files)
        csv << ["section", section.key, nil, nil, entry.fetch("count"), JSON.generate(section.metadata)]
        section.record_sets.each { write_record_set_manifest(csv, section, it, entry, files) }
      end

      def write_record_set_manifest(csv, section, record_set, entry, files)
        csv << [
          "record_set",
          section.key,
          record_set.name,
          files[[section.key, record_set.name]],
          entry.fetch("record_sets").fetch(record_set.name),
          JSON.generate("columns" => record_set.columns,
                        "headers" => record_set.headers.map { self.class.csv_value(it) })
        ]
      end
    end
  end
end
