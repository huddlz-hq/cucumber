# Cucumber for Elixir

A Cucumber implementation that turns Gherkin feature files into ExUnit tests, matching each step's text against user-written step definitions.

## Language

### Steps and definitions

**Step definition**:
A pattern (cucumber expression or regular expression) paired with the code that runs when a step's text matches it.
_Avoid_: step implementation, step handler

**Parameter type**:
A named placeholder usable inside cucumber expressions, such as `{int}` or a user-registered `{color}`, that says what text it matches and how to convert it.
_Avoid_: custom type, param type

**Step registry**:
The complete set of step definitions and parameter types for a run, against which every step's text is matched.
_Avoid_: step map, step table

**Undefined step**:
A step whose text matches no step definition in the step registry.
_Avoid_: missing step, unknown step

**Ambiguous step**:
A step whose text matches more than one step definition in the step registry.
_Avoid_: duplicate match

### Running scenarios

**Pickle**:
One concrete, runnable scenario compiled from a feature: an outline row or plain scenario, with its background and rule background steps and inherited tags folded in.
_Avoid_: expanded scenario, scenario spec

**Test case**:
A pickle prepared to run: its ordered test steps, with every pickle step already matched against the step registry and every scenario hook already selected by tags. Step arguments are not part of it: they are converted when each step runs. The generated ExUnit test runs one test case, possibly over several attempts.
_Avoid_: plan, scenario spec (and don't confuse it with an ExUnit test module)

**Test step**:
One entry in a test case, either a hook step (a before or after scenario hook) or a pickle test step (one of the pickle's steps together with the step definitions it matches).
_Avoid_: plan entry, step match
