# frozen_string_literal: true

require "minitest/autorun"
require "export_kit"
require "tmpdir"
require "open3"
require "timeout"

class CoreTest < Minitest::Test
  def test_nested_json_without_rails
    refute defined?(Rails)
    refute defined?(ActiveRecord)
    data = { "products" => [{ "name" => "Łódź", "price" => 12, "tags" => [nil, true] }] }
    artifact = ExportKit.render(data, format: :json, max_bytes: 4096).value!
    assert_equal data, JSON.parse(artifact.file.read)
    assert artifact.verify.success?
    artifact.cleanup
    artifact.cleanup
    assert artifact.verify.failure?
  ensure
    artifact&.cleanup
  end

  def test_table_keeps_keys_in_json_and_labels_in_csv
    table = ExportKit::Table.new(columns: %i(name tags), labels: { name: "Nazwa", tags: "Tagi" },
                                 rows: [{ "name" => "=2+2", "tags" => ["a"] }])
    json = ExportKit.render(table, format: :json, max_bytes: 4096).value!
    csv = ExportKit.render(table, format: :csv, max_bytes: 4096).value!
    assert_equal [{ "name" => "=2+2", "tags" => ["a"] }], JSON.parse(json.file.read)
    assert_equal [["Nazwa", "Tagi"], ["'=2+2", '["a"]']], CSV.parse(csv.file.read)
    assert json.verify.success?
    assert csv.verify.success?
  ensure
    json&.cleanup
    csv&.cleanup
  end

  def test_result_composition
    value = ExportKit::Result.success(3).map { it + 1 }.and_then { ExportKit::Result.success(it * 2) }
    assert_equal 8, value.value!
    failure = ExportKit::Result.failure(:bad)
    assert_same(failure, failure.map { flunk }.and_then { flunk })
    assert_equal :other, failure.map_error { :other }.error
    assert_raises(ExportKit::Result::ValueError) { failure.value! }
    assert_nil failure.value
  end

  def test_core_entrypoint_does_not_load_rails_or_active_record
    output, status = Open3.capture2(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e",
                                    'require "export_kit"; abort if defined?(Rails) || defined?(ActiveRecord)')
    assert status.success?, output
  end

  def test_document_formats_and_structural_validation
    artifact = nil
    %w(json csv_zip pdf).each do |format|
      artifact = ExportKit.render(document, format:, max_bytes: 1_000_000, font: font_path).value!
      assert artifact.verify.success?, format
      assert ExportKit.validate(artifact).success?, format
      assert_equal 2, artifact.manifest.first.fetch("count")
      artifact.close!
    end
  ensure
    artifact&.close!
  end

  def test_pdf_requires_an_explicit_font
    result = ExportKit.render(document, format: :pdf, max_bytes: 1_000_000)
    assert_equal ExportKit::Render::RENDER_FAILED, result.error
  end

  def test_custom_layout_and_bounded_output
    renderer = Object.new
    renderer.define_singleton_method(:call) do |input:, output:, **|
      raise "raw path exposed" if output.respond_to?(:path) || output.respond_to?(:to_io)

      pdf = Prawn::Document.new
      pdf.text input.fetch(:title)
      pdf.render(output)
    end
    artifact = ExportKit.render({ title: "Label" }, format: :pdf, max_bytes: 50_000, renderer:).value!
    assert File.binread(artifact.file.path).start_with?("%PDF-")
    assert artifact.verify.success?
    result = ExportKit.render({ title: "Label" }, format: :pdf, max_bytes: 5, renderer:,
                              extension: "pdf", content_type: "application/pdf")
    assert_equal ExportKit::Render::TOO_LARGE, result.error
  ensure
    artifact&.close!
  end

  def test_unexpected_renderer_and_source_exceptions_clean_all_temporary_files
    in_private_tmpdir do |directory|
      renderer = Object.new
      renderer.define_singleton_method(:call) do |output:, **|
        output.write("partial")
        raise NoMethodError, "programming error"
      end
      assert_raises(NoMethodError) do
        ExportKit.render(nil, format: :custom, renderer:, max_bytes: 100,
                         extension: "txt", content_type: "text/plain")
      end
      %w(json csv_zip pdf).each do |format|
        source = lambda do |&emit|
          emit.call({ "name" => "first" })
          raise NoMethodError, "source bug"
        end
        assert_raises(NoMethodError) do
          ExportKit.render(document(source:), format:, font: font_path, max_bytes: 1_000_000)
        end
      end
      assert_empty Dir.children(directory)
    end
  end

  def test_later_invalid_row_is_located_without_leaking_values
    in_private_tmpdir do |directory|
      source = lambda do |&emit|
        emit.call({ "name" => "good" })
        emit.call({ "name" => { "secret" => "CANARY-PRIVATE" } })
        flunk "must stop at the first failure"
      end
      %w(json csv_zip pdf).each do |format|
        result = ExportKit.render(document(source:), format:, font: font_path, max_bytes: 1_000_000)
        assert_equal ExportKit::Render::RENDER_FAILED, result.error
        assert_equal({ section: "people", record_set: "users", row: 2, column: "name" }, result.error_details)
        mapped = result.map_error { :application_error }
        assert_equal result.error_details, mapped.error_details
        assert mapped.error_details.frozen?
        assert mapped.error_details[:column].frozen?
        refute_includes mapped.inspect, "CANARY-PRIVATE"
        assert_nil mapped.value
      end
      assert_empty Dir.children(directory)
    end
  end

  def test_untrusted_extra_keys_are_not_in_error_details
    table = ExportKit::Table.new(columns: [:name], rows: [{ "private/CANARY" => "secret" }])
    result = ExportKit.render(table, format: :json, max_bytes: 1000)
    assert_equal({ record_set: "rows", row: 1, column: "name" }, result.error_details)
    refute_includes result.inspect, "CANARY"
  end

  def test_limits_stop_lazy_rows_and_leave_no_partial_artifacts
    in_private_tmpdir do |directory|
      %w(json csv_zip pdf).each do |format|
        source = lambda do |&emit|
          100.times { emit.call({ "name" => "x" * 1000 }) }
        end
        result = ExportKit.render(document(source:), format:, font: font_path, max_bytes: 2000)
        assert_equal ExportKit::Render::TOO_LARGE, result.error, format
      end
      emitted = 0
      rows = lambda do |&emit|
        loop do
          emitted += 1
          raise "not bounded" if emitted > 10

          emit.call({ "name" => "x" * 1000 })
        end
      end
      table = ExportKit::Table.new(columns: [:name], rows:)
      assert_equal ExportKit::Render::TOO_LARGE, ExportKit.render(table, format: :csv, max_bytes: 1500).error
      assert_equal 2, emitted
      assert_empty Dir.children(directory)
    end
  end

  def test_tampering_digest_and_structure_are_separate_checks
    artifact = ExportKit.render(document, format: :json, max_bytes: 4096).value!
    artifact.file.rewind
    artifact.file.truncate(0)
    artifact.file.write("{}")
    artifact.file.flush
    assert artifact.verify.failure?
    changed = artifact.with(byte_size: artifact.file.size, sha256: Digest::SHA256.file(artifact.file.path).hexdigest)
    assert changed.verify.success?
    assert ExportKit.validate(changed).failure?
  ensure
    artifact&.close!
  end

  def test_csv_validation_rejects_unexpected_manifest_rows_after_rehashing
    artifact = ExportKit.render(document, format: :csv_zip, max_bytes: 4096).value!
    entries = {}
    Zip::File.open(artifact.file.path) do |archive|
      archive.each { |entry| entries[entry.name] = entry.get_input_stream.read }
    end
    entries.fetch("manifest.csv") << CSV.generate_line(["unexpected", nil, nil, nil, nil, "{}"])
    artifact.file.rewind
    artifact.file.truncate(0)
    Zip::OutputStream.write_buffer(artifact.file) do |archive|
      entries.each do |name, contents|
        archive.put_next_entry(name)
        archive.write(contents)
      end
    end
    artifact.file.flush
    changed = artifact.with(byte_size: artifact.file.size,
                            sha256: Digest::SHA256.file(artifact.file.path).hexdigest)

    assert ExportKit.validate(changed).failure?
  ensure
    artifact&.close!
  end

  def test_unknown_format_and_invalid_json_are_controlled_failures
    assert_equal ExportKit::Render::FORMAT_UNSUPPORTED, ExportKit.render({}, format: :xml, max_bytes: 100).error
    [Object.new, Float::NAN, { "bad" => Object.new }].each do |input|
      assert_equal ExportKit::Render::RENDER_FAILED, ExportKit.render(input, format: :json, max_bytes: 100).error
    end
  end

  def test_duplicate_json_keys_and_failure_without_error_are_rejected
    result = ExportKit.render({ :name => 1, "name" => 2 }, format: :json, max_bytes: 4096)
    assert_equal ExportKit::Render::RENDER_FAILED, result.error
    assert_raises(ArgumentError) { ExportKit::Result.failure(nil) }
    assert_raises(ArgumentError) { ExportKit::Result.failure(:bad).map_error { nil } }
  end

  def test_table_normalizes_keys_and_order_without_silently_dropping_data
    table = ExportKit::Table.new(columns: %i(name tags), rows: [{ tags: [], name: "ok" }])
    artifact = ExportKit.render(table, format: :json, max_bytes: 4096).value!
    assert_equal [{ "name" => "ok", "tags" => [] }], JSON.parse(artifact.file.read)
    [{ :name => "x", "name" => "y", :tags => [] }, { name: "x" },
     { name: "x", tags: [], extra: "CANARY" }].each do |row|
      table = ExportKit::Table.new(columns: %i(name tags), rows: [row])
      result = ExportKit.render(table, format: :json, max_bytes: 4096)
      assert_equal ExportKit::Render::RENDER_FAILED, result.error
      assert_equal 1, result.error_details[:row]
      refute_includes result.inspect, "CANARY"
    end
  ensure
    artifact&.close!
  end

  def test_document_metadata_cannot_override_envelope_or_manifest
    %w(format schema_version manifest data).each do |key|
      assert_raises(ArgumentError) do
        ExportKit::Document.new(identifier: "example", schema_version: 1, title: "Example",
                                metadata: { key => "override" }, sections: [])
      end
    end
    %w(category label description record_sets count).each do |key|
      assert_raises(ArgumentError) do
        ExportKit::Document::Section.new(key: "example", label: "Example", description: "",
                                         metadata: { key => "override" }, record_sets: [])
      end
    end
  end

  def test_document_copies_names_labels_and_collections_before_validation
    name = +"users"
    column = +"name"
    label = +"=Name"
    columns = [column]
    set = ExportKit::Document::RecordSet.new(name:, columns:, column_labels: { column => label },
                                             row_source: ->(&emit) { emit.call({ "name" => "ok" }) })
    name.replace("../../secret")
    column.replace("private")
    label.replace("CANARY")
    columns.clear
    section = ExportKit::Document::Section.new(key: "people", label: "People", description: "",
                                               metadata: {}, record_sets: [set])
    input = ExportKit::Document.new(identifier: "example", schema_version: 1, title: "Example",
                                    metadata: {}, sections: [section])
    artifact = ExportKit.render(input, format: :csv_zip, max_bytes: 4096).value!
    assert ExportKit.validate(artifact).success?
    Zip::File.open(artifact.file.path) do |zip|
      assert_equal ["data/people/users.csv", "manifest.csv"], zip.entries.map(&:name).sort
      assert_equal [["'=Name"], ["ok"]], CSV.parse(zip.read("data/people/users.csv"))
    end
  ensure
    artifact&.close!
  end

  def test_two_concurrent_renders_consume_each_source_once
    ready = Queue.new
    start = Queue.new
    calls = [0, 0]
    threads = 2.times.map do |index|
      Thread.new do
        rows = lambda do |&emit|
          calls[index] += 1
          ready << true
          start.pop
          emit.call({ "name" => "value-#{index}" })
        end
        input = ExportKit::Table.new(columns: [:name], rows:)
        artifact = ExportKit.render(input, format: :json, max_bytes: 4096).value!
        [artifact.file.path, JSON.parse(artifact.file.read)]
      ensure
        artifact&.close!
      end
    end
    results = Timeout.timeout(10) do
      2.times { ready.pop }
      2.times { start << true }
      threads.map(&:value)
    end
    assert_equal [1, 1], calls
    assert_equal 2, results.map(&:first).uniq.size
    assert_equal [[{ "name" => "value-0" }], [{ "name" => "value-1" }]], results.map(&:last)
    results.each { refute File.exist?(it.first) }
  ensure
    stop_threads(threads)
  end

  def test_argument_error_in_custom_renderer_is_a_bug_and_cleans_output
    in_private_tmpdir do |directory|
      renderer = lambda do |input:, output:, **|
        output.write(input)
        raise ArgumentError, "bad arity"
      end
      assert_raises(ArgumentError) do
        ExportKit.render("partial", format: :json, max_bytes: 4096, renderer:)
      end
      assert_empty Dir.children(directory)
    end
  end

  def test_encoding_and_nonfinite_field_values_have_safe_location
    ["\xFF".b, Float::NAN].each do |value|
      table = ExportKit::Table.new(columns: [:name], rows: [{ "name" => "ok" }, { "name" => value }])
      result = ExportKit.render(table, format: :json, max_bytes: 4096)
      assert_equal({ record_set: "rows", row: 2, column: "name" }, result.error_details)
    end
  end

  private

  def stop_threads(threads)
    Array(threads).each do |thread|
      thread.kill
      thread.join(1)
    end
  end

  def document(source: nil)
    source ||= ->(&emit) { [{ "name" => "Łukasz" }, { "name" => "=2+2" }].each(&emit) }
    set = ExportKit::Document::RecordSet.new(name: "users", columns: [:name], row_source: source)
    section = ExportKit::Document::Section.new(key: "people", label: "Osoby", description: "Próba",
                                               metadata: { private: true }, record_sets: [set])
    ExportKit::Document.new(identifier: "personal_data", schema_version: 1, title: "Dane",
                            metadata: { subject: { user_id: 4 } }, sections: [section])
  end

  def font_path
    paths = ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
             "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"]
    paths.find { File.file?(it) } || raise("test requires a Unicode font")
  end

  def in_private_tmpdir
    previous = ENV.fetch("TMPDIR", nil)
    Dir.mktmpdir("export-kit-test") do |directory|
      ENV["TMPDIR"] = directory
      yield directory
    ensure
      ENV["TMPDIR"] = previous
    end
  end
end
