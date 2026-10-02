# frozen_string_literal: true

require "tempfile"

module ExportKit
  module Renderers
    # Canonical, structured representation of an export document.
    class Json < Base
      def render(document:, output:, max_bytes:)
        data_file = Tempfile.new(%w(export-kit-data .json), binmode: true)
        manifest = write_data(document, Output.new(io: data_file, max_bytes:), max_bytes)
        assemble(document, manifest, data_file, output, max_bytes)
        manifest
      ensure
        data_file&.close!
      end

      private

      def write_data(document, data_file, max_bytes)
        data_file.write("{")
        manifest = document.sections.each_with_index.map do |section, section_index|
          data_file.write(",") if section_index.positive?
          data_file.write("#{JSON.generate(section.key)}:")
          counts = write_section(section, data_file, max_bytes)
          manifest_entry(section, counts)
        end
        data_file.write("}")
        manifest
      end

      def write_section(section, data_file, max_bytes)
        data_file.write("{")
        counts = section.record_sets.each_with_index.to_h do |record_set, set_index|
          data_file.write(",") if set_index.positive?
          data_file.write("#{JSON.generate(record_set.name)}:")
          [record_set.name, write_rows(record_set, data_file, max_bytes)]
        end
        data_file.write("}")
        counts
      rescue InvalidDocument => e
        raise e.at(section: section.key)
      end

      def write_rows(record_set, data_file, max_bytes)
        data_file.write("[")
        count = 0
        each_row(record_set) do |row|
          data_file.write(",") if count.positive?
          data_file.write(JSON.generate(row))
          count += 1
          ensure_size!(data_file, max_bytes)
        end
        data_file.write("]")
        count
      end

      def assemble(document, manifest, data_file, output, max_bytes)
        header = JSON.generate(document.envelope(manifest))
        output.write(header.delete_suffix("}"), ",\"data\":")
        data_file.rewind
        output.copy_from(data_file)
        output.write("}")
        output.flush
        ensure_size!(output, max_bytes)
      end
    end
  end
end
