# frozen_string_literal: true

module ExportKit
  class Render
    FORMAT_UNSUPPORTED = :export_format_unsupported
    TOO_LARGE = :export_too_large
    RENDER_FAILED = :export_render_failed

    def initialize(data:, format:, max_bytes:, renderer: nil, content_type: nil, extension: nil,
                   font: nil, bold_font: nil, **options)
      @data = data
      @format = format.to_s
      @max_bytes = max_bytes
      @renderer = renderer
      @content_type = content_type
      @extension = extension
      @fonts = { normal: font, bold: bold_font }
      @options = options.merge(font:, bold_font:).freeze
    end

    def call
      validate_limit!
      definition = format_definition
      return Result.failure(FORMAT_UNSUPPORTED) unless definition
      return Result.failure(RENDER_FAILED) unless supported_data?

      render_file(definition)
    rescue Renderers::TooLarge
      Result.failure(TOO_LARGE)
    rescue JSON::GeneratorError, EncodingError, Renderers::InvalidDocument,
           Prawn::Errors::IncompatibleStringEncoding, Prawn::Errors::CannotFit, Zip::Error => e
      Result.failure(RENDER_FAILED, error_details: e.respond_to?(:error_details) ? e.error_details : {})
    end

    private

    attr_reader :content_type, :data, :extension, :fonts, :format, :max_bytes, :renderer, :options

    def render_file(definition)
      file = Tempfile.new(["export-kit", ".#{definition.extension}"], binmode: true)
      output = Output.new(io: file, max_bytes:)
      manifest = render_to(output)
      output.flush
      file.rewind
      artifact = build_artifact(file, definition, manifest)
      Result.success(artifact)
    ensure
      file&.close! unless artifact
    end

    def validate_limit!
      return if max_bytes.is_a?(Integer) && max_bytes.positive?

      raise Renderers::InvalidDocument, "max_bytes must be a positive integer"
    end

    def format_definition
      return FormatRegistry.find(format) unless renderer

      registered = FormatRegistry.find(format)
      custom_extension = extension || registered&.extension
      custom_type = content_type || registered&.content_type
      validate_descriptor!(custom_extension, custom_type)
      FormatRegistry::Definition.new(key: format, extension: custom_extension, content_type: custom_type)
    end

    def validate_descriptor!(custom_extension, custom_type)
      unless valid_descriptor?(custom_extension, /\A[a-z0-9]{1,12}\z/) &&
             valid_descriptor?(custom_type, %r{\A[\w.+-]+/[\w.+-]+\z})
        raise Renderers::InvalidDocument, "custom renderers require an extension and content type"
      end
    end

    def valid_descriptor?(value, pattern)
      value.is_a?(String) && value.match?(pattern)
    end

    def supported_data?
      return true if renderer || format == "json"
      return data.is_a?(Table) if format == "csv"

      data.is_a?(Document)
    end

    def render_to(output)
      if renderer
        renderer.call(input: data, output:, options:)
        return nil
      end
      return render_document(output) if data.is_a?(Document)
      return render_table(output) if data.is_a?(Table)

      write_json(data, output)
      nil
    end

    def render_document(output)
      implementation = case format
                       when "json" then Renderers::Json.new
                       when "csv_zip" then Renderers::CsvArchive.new
                       when "pdf" then Renderers::Pdf.new(fonts:)
                       end
      implementation.render(document: data, output:, max_bytes:)
    end

    def render_table(output)
      format == "json" ? write_json_rows(output) : write_csv_rows(output)
      nil
    end

    def write_json_rows(output)
      output.write("[")
      separator = ""
      each_table_row do |row|
        output.write(separator)
        write_json(row, output)
        separator = ","
      end
      output.write("]")
    end

    def write_csv_rows(output)
      csv = CSV.new(output)
      csv << data.headers.map { Renderers::CsvArchive.csv_value(it) }
      each_table_row do |row|
        csv << data.columns.map { Renderers::CsvArchive.csv_value(row.fetch(it)) }
      end
    end

    def each_table_row(&)
      Renderers::Base.new.send(:each_row, data, &)
    end

    def write_json(value, output, depth = 0)
      raise Renderers::InvalidDocument, "JSON nesting exceeds limit" if depth > 100

      case value
      when Hash then write_json_hash(value, output, depth)
      when Array then write_json_array(value, output, depth)
      when *Renderers::Base::SCALARS then output.write(JSON.generate(value))
      else raise Renderers::InvalidDocument, "unsupported JSON value"
      end
    end

    def write_json_hash(value, output, depth)
      validate_json_keys!(value.keys)
      output.write("{")
      value.each_with_index do |(key, item), index|
        output.write(",") if index.positive?
        output.write(JSON.generate(key.to_s), ":")
        write_json(item, output, depth + 1)
      end
      output.write("}")
    end

    def validate_json_keys!(keys)
      unless keys.all? { it.is_a?(String) || it.is_a?(Symbol) }
        raise Renderers::InvalidDocument, "JSON object keys must be strings or symbols"
      end

      normalized = keys.map(&:to_s)
      raise Renderers::InvalidDocument, "duplicate JSON keys" unless normalized.uniq == normalized
    end

    def write_json_array(value, output, depth)
      output.write("[")
      value.each_with_index do |item, index|
        output.write(",") if index.positive?
        write_json(item, output, depth + 1)
      end
      output.write("]")
    end

    def build_artifact(file, definition, manifest)
      document = data if data.is_a?(Document) || data.is_a?(Table)
      Artifact.new(file:, byte_size: file.size, sha256: Digest::SHA256.file(file.path).hexdigest,
                   manifest:, format:, content_type: definition.content_type, extension: definition.extension,
                   **document_metadata, document:)
    end

    def document_metadata
      return { identifier: nil, schema_version: nil, metadata: {} } unless data.is_a?(Document)

      { identifier: data.identifier, schema_version: data.schema_version, metadata: data.metadata }
    end
  end
end
