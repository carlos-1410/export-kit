# frozen_string_literal: true

module ExportKit
  class Output
    def initialize(io:, max_bytes:)
      @io = io
      @max_bytes = max_bytes
      @written = 0
    end

    def write(*strings)
      bytes = strings.sum(&:bytesize)
      position = io.respond_to?(:pos) ? io.pos : written
      raise Renderers::TooLarge if position + bytes > max_bytes

      @written += bytes
      io.write(*strings)
    end

    def <<(string)
      write(string)
      self
    end

    def copy_from(source)
      while (chunk = source.read(16_384))
        write(chunk)
      end
    end

    def reopen(other)
      raise ArgumentError, "cannot replace export output" unless other.is_a?(Output) && io.equal?(other.send(:io))

      self
    end

    def seek(*) = io.seek(*)
    def pos = io.pos

    def pos=(position)
      raise Renderers::TooLarge if position > max_bytes

      io.pos = position
    end

    def size = io.size
    def flush = io.flush
    def rewind = io.rewind
    def tell = io.tell
    def binmode = self
    def close = flush
    def closed? = io.closed?

    private

    attr_reader :io, :max_bytes, :written
  end
end
