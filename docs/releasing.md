# Releasing

Releases are published from `.github/workflows/release.yml` with RubyGems trusted publishing.
No long-lived RubyGems token belongs in GitHub Actions.

1. Update `ExportKit::VERSION` and `CHANGELOG.md` in a pull request.
2. Merge only after CI succeeds.
3. Create and push an annotated `vX.Y.Z` tag from the release commit.
4. The release workflow verifies that the tag matches the gem version, builds the package and
   publishes it to RubyGems.org through OIDC.
5. Confirm the version and documentation on RubyGems.org, then create matching consumer updates.

The RubyGems trusted publisher must match:

- owner: `carlos-1410`
- repository: `export-kit`
- workflow: `release.yml`
- environment: `release`

Never publish from an unreviewed working tree or reuse a released version number.
