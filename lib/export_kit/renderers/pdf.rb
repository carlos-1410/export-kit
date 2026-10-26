# frozen_string_literal: true

require "prawn"

module ExportKit
  module Renderers
    # Human-readable presentation of the same logical document. All source values are plain text;
    # Prawn never interprets them as HTML or inline markup.
    class Pdf < Base
      def initialize(fonts: nil)
        super()
        @fonts = fonts
      end

      def render(document:, output:, max_bytes:)
        manifest = render_pdf(document, output)
        ensure_size!(output, max_bytes)
        manifest
      end

      private

      attr_reader :fonts

      def render_pdf(document, output)
        pdf = Prawn::Document.new(page_size: "A4", margin: 42)
        configure_font(pdf)
        render_header(pdf, document)
        manifest = document.sections.map { render_page(pdf, it) }
        render_manifest(pdf, manifest)
        render_page_numbers(pdf)
        pdf.render(output)
        manifest
      end

      def render_page(pdf, section)
        pdf.start_new_page unless pdf.page_number == 1 && pdf.cursor > 300
        manifest_entry(section, render_section(pdf, section))
      end

      def configure_font(pdf)
        normal = fonts && fonts[:normal]
        bold = fonts && fonts[:bold]
        raise InvalidDocument, "Unicode PDF font is unavailable" unless normal && File.file?(normal)

        pdf.font_families.update("ExportSans" => { normal:, bold: bold || normal })
        pdf.font("ExportSans")
      end

      def render_header(pdf, document)
        pdf.text printable(document.title), size: 20, style: :bold
        pdf.move_down 12
        pdf.text "Format: #{printable(document.identifier)} · schema: #{document.schema_version}", size: 9
        document.metadata.each { |key, value| render_field(pdf, key, value, size: 8) }
      end

      def render_section(pdf, section)
        render_section_header(pdf, section)
        section.record_sets.to_h do |record_set|
          [record_set.name, render_record_set(pdf, record_set)]
        end
      rescue InvalidDocument => e
        raise e.at(section: section.key)
      end

      def render_section_header(pdf, section)
        pdf.text printable(section.label), size: 16, style: :bold
        pdf.text printable(section.description), size: 9 unless section.description.empty?
        pdf.move_down 10
      end

      def render_record_set(pdf, record_set)
        pdf.text printable(record_set.name), size: 12, style: :bold
        count = 0
        each_row(record_set) do |row|
          count += 1
          render_record(pdf, record_set, row, count)
        end
        pdf.text "—", size: 9 if count.zero?
        pdf.move_down 12
        count
      end

      def render_record(pdf, record_set, row, count)
        pdf.start_new_page if pdf.cursor < record_height(pdf, record_set, row, count)
        pdf.move_down 6
        pdf.text "##{count}", size: 9, style: :bold
        row.each { |key, value| render_field(pdf, record_set.column_labels.fetch(key), value) }
      end

      def record_height(pdf, record_set, row, count)
        heading_height = pdf.height_of("##{count}", size: 9, style: :bold)
        fields_height = row.sum do |key, value|
          pdf.height_of(field_text(record_set.column_labels.fetch(key), value), size: 8, leading: 1)
        end
        6 + heading_height + fields_height
      end

      def render_field(pdf, key, value, size: 8)
        pdf.text field_text(key, value), size:, leading: 1
      end

      def field_text(key, value)
        rendered = value.is_a?(Array) ? JSON.generate(value) : value.to_s
        "#{printable(key)}: #{printable(rendered)}"
      end

      def render_manifest(pdf, manifest)
        pdf.start_new_page
        pdf.text "Manifest", size: 16, style: :bold
        pdf.move_down 8
        manifest.each do |entry|
          pdf.text "#{printable(entry.fetch('label'))}: #{entry.fetch('count')}", size: 9
        end
      end

      def render_page_numbers(pdf)
        pdf.number_pages("<page> / <total>", at: [pdf.bounds.right - 70, -18], width: 70, align: :right, size: 8)
      end

      def printable(value)
        value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
             .gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/, " ")
      end
    end
  end
end
