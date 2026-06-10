# Cucumber Compatibility Kit fixtures

Feature files vendored from the [Cucumber Compatibility Kit](https://github.com/cucumber/compatibility-kit)
(`devkit/samples/`), MIT License, Copyright (c) 2020 Cucumber Ltd and contributors.

These are the canonical behavior sources for this implementation's behavior
tests (see `Cucumber.BehaviorCase`). Each sample directory mirrors the CCK
layout; the Elixir step definitions equivalent to the kit's reference
TypeScript step definitions live alongside the behavior tests in
`test/cucumber/behavior/`.

They are deliberately **not** under `test/features/` — several samples
represent failing test runs and must never join the live suite. More samples
get vendored as the features they exercise are implemented (see issues #17–#29).
