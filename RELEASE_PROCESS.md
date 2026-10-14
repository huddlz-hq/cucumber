# Release process

## Prepare

1. Update the version in `mix.exs` and the release notes in `CHANGELOG.md`.
2. Commit the changes, merge to `main`, and wait for CI to pass on that commit.
3. Use the toolchain in `mise.toml`, install dependencies with `mix deps.get`, and
   authenticate with Hex. Hex sessions expire: check with `mix hex.user whoami`
   and run `mix hex.user auth` if it fails, so publishing doesn't stop after a
   full validation run. The checkout must have an `origin` remote.
4. Run the preflight from a clean, up-to-date `main` checkout. If your usual
   checkout has work in progress, `git worktree add <dir> main` (then
   `git pull --ff-only` in it) gives a clean one without disturbing that work:

   ```sh
   ./scripts/release.sh <version> --check
   ```

`--check` runs all release validation without publishing, creating tags, or pushing.
It requires network access for the dependency audit and remote tag lookup.
Remove or commit untracked files first. Ignored build output is allowed, but every
file selected for the Hex package must match the release commit byte for byte.
This catches ignored files accidentally placed under packaged directories too.

## Publish

```sh
./scripts/release.sh <version>
```

Run this in an interactive terminal: `mix hex.publish` asks for confirmation (and
may ask for your Hex password), so the script cannot run unattended from CI, a
pipe, or an agent.

The script checks the branch, clean checkout, version, and local/remote tags;
runs validation; verifies the actual package contents against the original commit;
and rechecks the checkout and tags before invoking `mix hex.publish` in the dev
environment (so ExDoc is available). Existing lightweight or annotated tags are
accepted only when they resolve to the release commit.

After successful publication it creates the tag if needed, then atomically pushes
that tag and the validated commit to `main`. It does not edit the version or
changelog, create a release commit, or repair formatting. Then create the GitHub
release with the version's changelog section as its notes, either from the printed
link or with `gh release create v<version> --title v<version> --notes-file <file>`.

Hex publication and Git pushes cannot be one transaction. If publishing partially
succeeds or the push fails, inspect Hex and the remote before retrying. Once Hex
confirms the package and docs are published, a failed Git push can be retried with
`git push --atomic origin main refs/tags/v<version>` from the same validated commit.
Do not move an existing release tag to a different commit.

## Validation coverage

`mix validate` is the source of truth for CI and release checks and can also be
run locally. Its
alias in `mix.exs` audits dependencies, compiles with warnings as errors, checks
formatting, runs strict Credo, checks for unused lockfile entries, and runs the
full default test suite (including pinned CCK approvals, Messages schema
validation, and fixture integrity). It also runs the release-script safety tests
and starts a separate dev-environment Mix process to build the package, compile,
and build docs with warnings as errors, so dev-only ExDoc is available.

The command writes build outputs but does not modify source or the lockfile.
`mix precommit` keeps its existing development workflow: compile, format source,
run strict Credo, remove unused lockfile entries, and run tests. Use it to clean
up automatically, then run `mix validate` for the complete CI/release checks.

CI tests Elixir 1.18.0 / OTP 26 (the declared minimum), Elixir 1.19 / OTP 28, and
Elixir 1.20.4 / OTP 28 and 29. These follow the upstream
[Elixir/OTP compatibility table](https://elixir.hexdocs.pm/main/compatibility-and-deprecations.html).
Every matrix entry runs `mix validate`; the Elixir 1.20.4 / OTP 29 entry also
verifies pinned CCK provenance against GitHub. Upstream drift (`scripts/check_cck.exs main`) remains an explicit
maintenance check, not a release gate against a moving target. Performance
benchmarks remain opt-in.

Run `bash scripts/test_release.sh` to exercise release failures and successful
ordering with temporary Git repositories and mocked Mix/push commands. It never
publishes a package or contacts a remote service.

## Version numbering

Use [Semantic Versioning](https://semver.org/): major for incompatible changes,
minor for backward-compatible features, and patch for backward-compatible fixes.
