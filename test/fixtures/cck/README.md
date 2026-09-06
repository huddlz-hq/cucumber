# Cucumber Compatibility Kit fixtures

Feature files and reference `.ndjson` message streams vendored from the
[Cucumber Compatibility Kit](https://github.com/cucumber/compatibility-kit)
(`devkit/samples/`), MIT License, Copyright (c) 2020 Cucumber Ltd and
contributors. `attachments/document.pdf` is the binary the attachments
sample attaches.

These are the canonical behavior sources for this implementation's behavior
tests (see `Cucumber.BehaviorCase`). Each sample directory mirrors the CCK
layout; the Elixir step definitions equivalent to the kit's reference
TypeScript step definitions live alongside the behavior tests in
`test/cucumber/behavior/` and, for the approval suite, in
`test/support/cck/approval_definitions.ex`.

The approval suite (`test/cucumber/cck_approval_test.exs`) runs every
sample with the Cucumber Messages sink enabled and compares the emitted
NDJSON to the sample's reference `.ndjson`, normalized by
`Cucumber.CckApproval`. Samples the CCK ships that are not approved here
are listed with reasons in the approval test's moduledoc.

They are deliberately **not** under `test/features/` — several samples
represent failing test runs and must never join the live suite.

## Provenance

Every vendored sample file matches upstream commit
`bed15e9c30fb5e37c19be7ecfe6aa2a2f7d890f7` byte for byte. `upstream.json`
records the full 46-sample inventory and upstream Git blob hashes.
`mix test test/cucumber/cck_fixtures_test.exs` checks this offline;
`MIX_ENV=test mix run scripts/check_cck.exs` verifies it against GitHub.
Pass `main` to the script to detect upstream drift. See
[compatibility boundaries](../../../docs/compatibility.md) for the complete
sample/allowance matrix and update procedure.
