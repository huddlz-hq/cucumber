# Cucumber for Elixir

Executable specifications written in Gherkin and run as ExUnit tests. These
terms name the parts of a specification and the evidence a run produces.

## Language

### Specifications

**Step**:
One line of a scenario that starts with a keyword (`Given`, `When`, `Then`,
`And`, `But`, `*`) and is matched to a step definition.

**Step argument**:
A data table or doc string written beneath a step and handed to that step
alone. A step has at most one of each.
_Avoid_: attachment, step attachment, multiline argument

**Data table**:
A step argument made of pipe-delimited rows.
_Avoid_: datatable (outside code), table argument

**Doc string**:
A step argument made of free text between `"""` or ```` ``` ```` delimiters,
optionally labeled with a media type.
_Avoid_: docstring (outside code), heredoc, text block

**Argument order**:
The source order of a step's data table and doc string when the step has both.
_Avoid_: argument index (the Messages field that encodes it)

**Pickle**:
One executable scenario after outline expansion and background inlining.
_Avoid_: test case (that is the run-time plan for a pickle)

### Run evidence

**Attachment**:
Content a running step or hook adds to the report with `Cucumber.attach`.
_Avoid_: step argument
