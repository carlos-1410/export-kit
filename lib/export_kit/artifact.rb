# frozen_string_literal: true

module ExportKit
  Artifact = Data.define(:file, :byte_size, :sha256, :manifest, :format, :content_type, :extension,
                         :identifier, :schema_version, :metadata, :document) do
    def close!
      file.close!
      nil
    end
    alias_method :cleanup, :close!

    def verify
      valid ? Result.success(self) : Result.failure(ValidateArtifact::INVALID)
    rescue Errno::ENOENT, IOError
      Result.failure(ValidateArtifact::INVALID)
    end

    private

    def valid = file.path && File.size(file.path) == byte_size && Digest::SHA256.file(file.path).hexdigest == sha256
  end
end
