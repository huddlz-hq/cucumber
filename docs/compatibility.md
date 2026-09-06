# Compatibility boundaries

Cucumber for Elixir runs 40 of 46 samples from the Cucumber Compatibility Kit
(CCK) at commit `bed15e9c30fb5e37c19be7ecfe6aa2a2f7d890f7`. All vendored feature
files, reference streams, and the attachment PDF match that revision byte for
byte. These approvals establish compatibility for the covered behavior subject
to the allowances below; they do not establish complete Cucumber, Gherkin,
Cucumber Expressions, or formatter compatibility.

## Messages contract

The emitter declares **Messages 33.0.2**. Its unmodified authoritative JSON
Schema bundle is vendored at `test/fixtures/messages/messages.schema.json`, from
[cucumber/messages commit 7f9c117](https://github.com/cucumber/messages/tree/7f9c117785b0547b09d7570e54b46b393d7e91fb)
(tag `v33.0.2`). Version 27 previously advertised by the emitter was inaccurate:
the emitter already used newer shapes, including run-hook events and run IDs.
The version change is backed by validating every raw envelope in all supported
samples against 33.0.2, including metadata and fields later removed for comparison.

`Cucumber.CckSchema` is a test-only, dependency-free evaluator of the vocabulary
used by this pinned bundle: references (including document-local definitions),
objects, arrays, required/unknown properties, scalar types, enums, numeric bounds,
and minimum array lengths. Unknown validation keywords fail closed. It is not a
general JSON Schema engine. Schema validation proves the emitted shape; optional
fields and unimplemented message types are not promises of implemented features.

`Cucumber.CckStream` additionally checks one message per envelope, metadata first
and exactly once, globally unique IDs, references to earlier envelopes of the
right message type, one completed run, paired run hooks, and complete ordered
steps within each active attempt. Attachments must reference that attempt's active
step. Attempt state is independent so concurrent scenarios may interleave.
Both actual and reference streams pass these checks **before** approval
normalization. The Messages emission behavior tests also use these checks,
including abrupt process termination and hook failures. Mutation tests exercise
rejection paths and acceptance of interleaved attempts.

This validator targets complete execution streams for the supported subset. It
does not validate arbitrary partial streams, global-hook attachments, every
semantic relationship in the Messages model, or compatibility with every consumer.

## Sample matrix

| Coverage | Samples |
| --- | --- |
| Approved: basic execution and arguments | `minimal`, `cdata`, `empty`, `data-tables`, `backgrounds`, `doc-strings`, `examples-tables`, `unused-steps`, `stack-traces`, `parameter-types`, `regular-expression` |
| Approved: outcomes | `undefined`, `ambiguous`, `pending`, `skipped`, `all-statuses`, `failedish-combinations`, `undefined-multiple`, `examples-tables-undefined`, `examples-tables-undefined-multiple` |
| Approved: hooks | `hooks`, `hooks-conditional`, `hooks-named`, `hooks-skipped`, `skipped-failing-hook`, `global-hooks`, `global-hooks-afterall-error`, `hooks-undefined` |
| Approved: retries | `retry`, `retry-pending`, `retry-undefined` |
| Approved: structure and attachments | `rules`, `rules-backgrounds`, `attachments`, `hooks-attachment`, `examples-tables-attachment`, `multiple-features` |
| Approved with additional behavior/representation allowances | `global-hooks-beforeall-error`, `retry-ambiguous`, `markdown` (details below) |
| Excluded: global-hook attachment support absent | `global-hooks-attachments` |
| Excluded: reference CLI reverse-order option absent; ExUnit controls order | `multiple-features-reversed` |
| Excluded: pending/skipped use return values here, not exceptions; return-value samples are approved | `pending-exception`, `skipped-exception` |
| Excluded: reference CLI runner-crash injection absent | `test-run-exception` |
| Excluded: discovery raises `Cucumber.UndefinedParameterTypeError` before a run, rather than emitting `undefinedParameterType` | `unknown-parameter-type` |

An inventory test requires every sample in the pinned upstream tree to be either
approved or explicitly excluded. Broader Gherkin parser/dialect and Cucumber
Expressions fixture adoption remains follow-up work, with separate fixture pins
and explicit support matrices needed for each.

## Comparison allowances

All approvals use these rules, implemented in `Cucumber.CckApproval`:

| Category | Allowance and boundary |
| --- | --- |
| Nondeterministic | Timestamps and durations are removed after raw type/range validation. IDs are consistently renumbered after raw uniqueness/reference checks. |
| Host/language specific | `meta` is omitted from equality, but validated and required to declare 33.0.2. `sourceReference` is removed because Elixir definitions differ from TypeScript. Error `message` and `exception` fields are removed because wording and stack traces differ. |
| Path representation | `uri` becomes its basename, ignoring fixture root paths. This does not prove disambiguation for duplicate basenames. |
| Parser representation | Every `column` is removed (our parser tracks lines). Descriptions have whitespace trimmed per line and at their boundaries. Exact columns and indentation are not approved. |
| Unsupported optional output | `stepMatchArgumentsLists` is removed: matching produces converted values, not source offsets. `suggestion` envelopes are removed: undefined-step suggestions are reported through errors rather than these envelopes. Parameter-type and hook source lines are not recorded; raw optional source references still undergo schema validation when present. |
| Valid emission order | Step definitions, hooks, and parameter types are sorted by content. Test cases are hoisted after `testRunStarted` for comparison; each raw case must already precede its attempt. |

Three sample-specific allowances remain:

| Sample | Additional allowance |
| --- | --- |
| `global-hooks-beforeall-error` | The reference aborts before creating cases. ExUnit still executes and fails scenarios with `Cucumber.BeforeAllError`. Case and step lifecycle envelopes are removed **only from equality**; our entire emitted lifecycle must validate first. This is a behavior difference. |
| `retry-ambiguous` | The reference registers identical patterns twice; discovery here rejects exact duplicates. Two distinct overlapping patterns reproduce ambiguity, and step-definition patterns are excluded from equality. |
| `markdown` | Only the feature description is excluded. The reference has tokenizer-recovery text `\| boz \| boo \|`; our Markdown parser emits no Markdown descriptions. |

## Reproduce and update

Offline checks (no GitHub access or extra validator dependency):

```sh
mix test test/cucumber/cck_approval_test.exs test/cucumber/cck_validation_test.exs test/cucumber/cck_fixtures_test.exs test/cucumber/behavior/messages_emission_test.exs
```

Verify the immutable fixture provenance online with GitHub CLI authentication:

```sh
MIX_ENV=test mix run scripts/check_cck.exs
```

Detect changed reference files or added/removed upstream samples:

```sh
MIX_ENV=test mix run scripts/check_cck.exs main
```

`test/fixtures/cck/upstream.json` records the upstream revision, complete sample
inventory, and upstream Git blob hashes for every vendored file. Normal tests
verify file contents and inventory against the manifest; the online check verifies
those hashes and the complete sample inventory against GitHub's tree API. It fails
on truncated trees or changed/new samples. Upstream files not vendored here
(including TypeScript definitions) are not byte-checked; review those when updating.

To update deliberately:

1. Resolve the desired CCK revision to a full commit SHA with `gh api
   repos/cucumber/compatibility-kit/commits/REV --jq .sha` and run the check against it.
2. Fetch its recursive Git tree using `gh api
   'repos/cucumber/compatibility-kit/git/trees/SHA?recursive=1'`. Review sample
   additions/removals, reference step definitions, and protocol changes.
3. Replace each tracked fixture from `devkit/samples/PATH` at that SHA using
   `gh api 'repos/cucumber/compatibility-kit/contents/devkit/samples/PATH?ref=SHA'
   -H 'Accept: application/vnd.github.raw+json'`. Add fixtures and Elixir definitions
   for newly supported samples, or explicitly classify exclusions.
4. Update `upstream.json` with that SHA, the sorted complete upstream sample list,
   and the Git tree's blob hashes for the selected paths. Do not bless locally
   modified reference output by hashing it into the manifest.
5. If adopting a new Messages version, vendor its schema and license unchanged,
   record its immutable revision and SHA-256, and review the validator vocabulary
   and emitted shapes before changing metadata. Run raw validation and approvals,
   resolve differences, and update this matrix. Finish with the online pinned check.
