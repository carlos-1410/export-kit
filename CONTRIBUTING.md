# Contributing

Bug reports and focused pull requests are welcome. Before opening a pull request:

```bash
bin/setup
bundle exec rake test
bundle exec rubocop
gem build export_kit.gemspec
```

Keep the core independent of Rails. Active Record integrations belong behind the explicit
`require "export_kit/active_record"` entry point. New output formats must preserve bounded writes,
temporary-file cleanup, safe error details and structural validation.

Do not include customer exports, production data, credentials or proprietary fonts in issues,
fixtures or pull requests.
