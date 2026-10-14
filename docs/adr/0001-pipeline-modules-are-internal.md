# Pipeline modules are internal, even though v1.0 documented them

`Cucumber.Discovery`, `Cucumber.Runtime` and `Cucumber.Compiler` shipped in v1.0 with public moduledocs, which made the step registry's internal shape (`DiscoveryResult.step_registry`, `Runtime.execute_step/4`) look like a supported interface. We mark them `@moduledoc false` and change their shapes in a 1.x minor release, with a CHANGELOG entry, rather than keeping deprecated shims or waiting for 2.0. Users drive the library through `Cucumber.compile_features!/1`, the `step` DSL, hooks, parameter types and `Cucumber.attach/4`; nobody realistically builds or reads registries, and freezing these shapes would have blocked deepening `Cucumber.StepRegistry`. `Cucumber.Expression.compile/2` and `match/2` stay public.

## Consequences

Future changes to Discovery, Runtime and Compiler are not semver-breaking. Do not re-expose them to tests or users. Tests and harnesses go through `Cucumber.StepRegistry` or `Cucumber.compile_features!/1`.

## Messages API

`Cucumber.Messages` and `Cucumber.Messages.Emitter` stay public in 1.x, because they were documented as public builders and are not part of the pipeline exception above. Their signatures that took the old registry shape keep working as `@deprecated` shims until 2.0: `Messages.step_definition/3` (in favour of `step_definition/2`, which takes a `Cucumber.StepRegistry.Definition`) and `Messages.Emitter.configure/6` (in favour of the internal `configure/5`; messages are enabled with `config :cucumber, messages: path`). In 2.0 the shims are removed and `Cucumber.Messages.Emitter` becomes internal.
