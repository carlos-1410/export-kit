# frozen_string_literal: true

module ExportKit
  class Result
    class ValueError < StandardError; end

    attr_reader :value, :error, :error_details

    def self.success(value) = new(value:, error: nil)

    def self.failure(error, error_details: {})
      raise ArgumentError, "error must be a symbol" unless error.is_a?(Symbol)

      new(value: nil, error:, error_details:)
    end

    def initialize(value:, error:, error_details: {})
      raise ArgumentError, "error must be a symbol" unless error.nil? || error.is_a?(Symbol)

      @value = value
      @error = error
      @error_details = safe_details(error_details)
      freeze
    end

    def success? = error.nil?
    def failure? = !success?

    def value!
      raise ValueError, error.to_s if failure?

      value
    end

    def map
      success? ? self.class.success(yield(value)) : self
    end

    def map_error
      failure? ? self.class.failure(yield(error), error_details:) : self
    end

    def and_then
      success? ? yield(value) : self
    end

    private

    def safe_details(details)
      details.each_with_object({}) do |(key, detail), safe|
        value = safe_detail(key, detail)
        safe[key] = value unless value.nil?
      end.freeze
    end

    def safe_detail(key, detail)
      return safe_row(detail) if key == :row
      return unless %i(section record_set column).include?(key)
      return unless detail.is_a?(String) || detail.is_a?(Symbol)

      detail.to_s.dup.freeze if detail.to_s.match?(Document::KEY_FORMAT)
    end

    def safe_row(detail)
      detail if detail.is_a?(Integer) && detail.positive?
    end
  end
end
