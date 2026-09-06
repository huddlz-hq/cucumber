# Release Process

This document outlines the process for creating and publishing new releases of the Cucumber package.

## Using the Release Script

The easiest way to create a release is to use the provided release script:

```bash
./scripts/release.sh <version>
```

For example:
```bash
./scripts/release.sh 0.2.0
```

The script will:

1. Check that you're on the main branch with a clean working directory
2. Update the version in `mix.exs`
3. Add a new entry to `CHANGELOG.md` and open it for editing
4. Run tests and generate documentation
5. Commit the version bump
6. Publish the package to Hex.pm
7. Create a Git tag for the version (only after successful publishing)
8. Push the changes and tag to GitHub

## Manual Release Process

If you prefer to release manually, follow these steps:

1. Update the version in `mix.exs`:
   ```elixir
   @version "0.2.0"
   ```

2. Update the `CHANGELOG.md` with details of changes in this version

3. Run tests to ensure everything works:
   ```bash
   mix test
   ```

4. Build documentation:
   ```bash
   mix docs
   ```

5. Commit the version bump:
   ```bash
   git add mix.exs CHANGELOG.md
   git commit -m "Bump version to 0.2.0"
   ```

6. Publish to Hex.pm:
   ```bash
   mix hex.publish
   ```

7. Create a Git tag (only after successful publishing):
   ```bash
   git tag v0.2.0
   ```

8. Push changes and tag to GitHub:
   ```bash
   git push origin main
   git push origin v0.2.0
   ```

9. Create a GitHub release:
   - Go to https://github.com/huddlz-hq/cucumber/releases/new
   - Select the tag you just created
   - Add release notes (can be copied from CHANGELOG.md)
   - Publish the release

## Version Numbering

This project follows [Semantic Versioning](https://semver.org/):

- MAJOR version for incompatible API changes (1.0.0)
- MINOR version for backward-compatible functionality additions (0.2.0)
- PATCH version for backward-compatible bug fixes (0.1.1)

During initial development (0.x.y), minor version increments may include breaking changes.