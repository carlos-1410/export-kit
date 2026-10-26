# ExportKit

Portable, size-bounded exports for Ruby applications.

ExportKit turns plain Ruby data, explicit tables or multi-section documents into JSON, CSV,
ZIP archives of CSV tables, and PDF. It streams rows, stops writing at a caller-provided byte
limit, neutralizes spreadsheet formulas, removes partial temporary files and can validate the
artifact it produced.

*(Dokumentacja po polsku: [README.pl.md](README.pl.md))*

## Why this exists

An export is more than `CSV.generate`: the caller must decide what may leave the application,
preserve a stable schema, avoid loading an unbounded dataset, prevent formula injection, clean up
temporary files and distinguish an expected refusal from a programming error. ExportKit owns those
format-neutral mechanics. The application still owns authorization and the business meaning of the
data.

The core does not load Rails or Active Record. The optional adapter is enabled explicitly.

## Installation

```ruby
gem "export_kit", "~> 0.1.0"
```

ExportKit requires Ruby 3.4 or newer.

## A single table

```ruby
require "export_kit"
require "fileutils"

table = ExportKit::Table.new(
  columns: %i[sku name price],
  labels: { sku: "SKU", name: "Name", price: "Price" },
  rows: [
    { sku: "LAMP-01", name: "Ceramic lamp", price: "149.00" },
    { sku: "CHAIR-02", name: "=HYPERLINK(...)", price: "320.00" }
  ]
)

result = ExportKit.render(table, format: :csv, max_bytes: 5 * 1024**2)

if result.success?
  artifact = result.value!
  begin
    FileUtils.copy_file(artifact.file.path, "products.csv")
  ensure
    artifact.close!
  end
else
  warn result.error
end
```

Column order is explicit. Every row must contain exactly the declared keys. CSV headers use the
labels, while JSON keeps the stable column keys. Strings beginning with `=`, `+`, `-` or `@` are
prefixed with an apostrophe in CSV output to prevent spreadsheet formula execution.

`rows` may also be a callback, which avoids materializing the whole dataset:

```ruby
rows = lambda do |&emit|
  source.each_batch { |batch| batch.each { |record| emit.call(record) } }
end

table = ExportKit::Table.new(columns: %i[id name], rows: rows)
```

The source is consumed synchronously and once per render.

## Plain JSON

Plain hashes and arrays can be rendered directly as JSON:

```ruby
result = ExportKit.render(
  { product: { sku: "LAMP-01", tags: ["vintage"] } },
  format: :json,
  max_bytes: 1_000_000
)
```

Supported values are hashes with string or symbol keys, arrays, strings, finite numbers, booleans
and `nil`. Nesting deeper than 100 levels is rejected.

## Multi-section documents

`ExportKit::Document` describes a versioned export independently of its output format. Each record
set is an explicit table backed by a row callback.

```ruby
users = ExportKit::Document::RecordSet.new(
  name: "users",
  columns: %i[id email],
  column_labels: { id: "ID", email: "Email" },
  row_source: ->(&emit) { authorized_users.find_each { |user| emit.call(id: user.id, email: user.email) } }
)

people = ExportKit::Document::Section.new(
  key: "people",
  label: "People",
  description: "Authorized user records",
  metadata: {},
  record_sets: [users]
)

document = ExportKit::Document.new(
  identifier: "account_export",
  schema_version: 1,
  title: "Account export",
  metadata: { requested_by: { user_id: 42 } },
  sections: [people]
)

result = ExportKit.render(document, format: :csv_zip, max_bytes: 20 * 1024**2)
```

Supported document formats:

| format | artifact | notes |
|---|---|---|
| `json` | `.json` | versioned envelope, manifest and section data |
| `csv_zip` | `.zip` | one UTF-8 CSV per non-empty record set plus `manifest.csv` |
| `pdf` | `.pdf` | human-readable A4 report; requires an explicit Unicode font |

For PDF, provide a font file owned by the consuming application:

```ruby
ExportKit.render(
  document,
  format: :pdf,
  max_bytes: 20 * 1024**2,
  font: Rails.root.join("app/assets/fonts/Inter-Regular.ttf").to_s,
  bold_font: Rails.root.join("app/assets/fonts/Inter-Bold.ttf").to_s
)
```

## Active Record adapter

Load the adapter explicitly:

```ruby
require "export_kit/active_record"
```

For a direct table, pass an authorized relation and a field allowlist:

```ruby
table = ExportKit.records(
  policy_scope(Order).reorder(nil),
  fields: %i[id number total_minor],
  labels: { number: "Order", total_minor: "Total (minor units)" },
  batch_size: 500
)
```

Models may define a complete export policy and use `fields: :all` in serializer definitions:

```ruby
class User < ApplicationRecord
  include ExportKit::ModelSchema

  export_schema do
    allow :id, :email
    timestamps
    omit :password_digest, :reset_token, reason: "authentication secrets"
  end
end

User.validate_export_schema!
```

The validation requires every database column to be either allowed or denied with a reason. This
is a schema ratchet, not authorization. The application must still provide the correct scoped
relation.

The batching adapter accepts an unordered, ungrouped relation without `offset` or `distinct`, and
requires a single primary key. It paginates by that primary key and respects an existing `limit`.

## Results and cleanup

Expected render failures are returned as `ExportKit::Result`:

| error | meaning |
|---|---|
| `export_format_unsupported` | no renderer exists for the requested format |
| `export_too_large` | the byte limit was exceeded |
| `export_render_failed` | input or renderer output was invalid |

`Result` provides `success?`, `failure?`, `value`, `value!`, `error`, `error_details`, `map`,
`map_error` and `and_then`. Safe error details may identify a section, record set, row and column;
they never contain the rejected value.

Programming errors from a custom renderer or row source propagate after temporary output is
removed. The caller owns a successful artifact and must call `close!` (or its alias `cleanup`) in
an `ensure` block.

## Validation

```ruby
artifact.verify                 # digest and byte count
ExportKit.validate(artifact)    # digest plus supported-format structure
```

Validation detects accidental corruption and malformed manifests. It does not prove that the
application selected every required record or excluded every private field.

## Security boundaries

ExportKit provides bounded writes, CSV formula neutralization, explicit schemas, safe error
locations, temporary-file cleanup and structural validation. It deliberately does not provide:

- authentication or authorization;
- tenant or policy scoping;
- transactional snapshots across several queries;
- encryption, object storage, downloads or retention;
- privacy-law completeness checks;
- a safe sandbox for custom renderers.

Treat custom renderers as trusted application code. Do not expose artifact paths in logs or error
responses. Set `max_bytes` from an application-level policy and deliver artifacts through an
authorized channel.

## Development

```bash
bin/setup
bundle exec rake test
bundle exec rubocop
gem build export_kit.gemspec
```

The test suite does not use the network. See [CONTRIBUTING.md](CONTRIBUTING.md),
[SECURITY.md](SECURITY.md) and [docs/releasing.md](docs/releasing.md).

## License

The gem is available under the [MIT License](LICENSE.txt).
