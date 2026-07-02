# Attachments

Cucumber lets you attach arbitrary data — screenshots, response payloads,
logs, links — while a scenario runs. Attachments are recorded against the
step (or hook execution) that attached them. Until a step fails they are
invisible; a failing step's error output lists everything the scenario
attached. When Cucumber Messages output is enabled (`config :cucumber,
messages: "path.ndjson"`), attachments are also emitted as `attachment`
envelopes in the message stream, attributed to their step or hook, where
standard Cucumber report tooling can render them.

## Attaching data

`Cucumber.attach/4` works from any step definition or hook and returns the
context unchanged, so it composes with any return style:

```elixir
step "the API responds", context do
  context
  |> Cucumber.attach(response.body, "application/json")
  |> Map.put(:response, response)
end
```

Strings are attached as-is. Binary data must be marked explicitly with
`{:bytes, binary}` — Elixir can't tell text from bytes by type — and is
Base64-encoded for transport:

```elixir
step "I take a screenshot", context do
  Cucumber.attach(context, {:bytes, screenshot()}, "image/png",
    filename: "checkout.png"
  )
end
```

## Convenience helpers

```elixir
# Attach a log message (media type text/x.cucumber.log+plain)
Cucumber.log(context, "user #{user.id} created")

# Attach a link (media type text/uri-list)
Cucumber.link(context, "https://dashboard.example.com/run/123")
```

## Attribution

Each `Cucumber.Attachment` records where it came from:

- `phase` — `:step`, `:before_scenario`, or `:after_scenario`
- `step_text` / `step_line` — the attaching step, when `phase` is `:step`
  (attachments from `before_step`/`after_step` hooks attribute to the step
  they bracket)
- `feature_file` / `scenario_name` — the owning scenario

Attachments from concurrent `@async` scenarios are recorded safely and
keep their own scenario's attribution.

## Failure output

When a step fails, its error message ends with the scenario's attachments:

```text
Attachments:

  * text/x.cucumber.log+plain: starting checkout flow
  * image/png (checkout.png): 18432 bytes, base64-encoded
```
