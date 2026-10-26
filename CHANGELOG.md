# Changelog

## [0.1.1] - 2026-10-26

- Neutralizes CSV formulas even when spreadsheet whitespace or control characters hide the dangerous prefix.

## [0.1.0] - 2026-10-26

First public release.

- Renders hashes and explicit tables as JSON or CSV.
- Renders multi-section documents as JSON, ZIP archives of CSV tables, or PDF.
- Enforces a caller-provided output-size limit while data is written.
- Neutralizes spreadsheet formulas in CSV cells.
- Returns typed results for expected failures and removes partial temporary files.
- Verifies artifact digests and validates the structure of supported formats.
- Provides an optional Active Record adapter with explicit allow/deny schemas and keyset batching.
