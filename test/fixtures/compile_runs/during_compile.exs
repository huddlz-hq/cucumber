# Pause compilation of the second feature until the first async scenario has
# attached evidence. This forces the scheduling that previously lost messages.
defmodule CompileRuns.Gate do
  def trace(:start, %{file: "second.feature"}) do
    receive do
      :first_recorded ->
        send(CompileRuns.Driver, :passed_gate)
        :ok
    after
      5_000 -> raise "first scenario did not run during compilation"
    end
  end

  def trace(_event, _env), do: :ok
end

[path] = System.argv()
File.cd!(__DIR__)
ExUnit.start(autorun: false)
Process.register(self(), CompileRuns.Driver)
Application.put_env(:cucumber, :messages, path)
Code.put_compiler_option(:tracers, [CompileRuns.Gate])
runner = ExUnit.async_run()

Cucumber.compile_features!(
  features: ["first.feature", "second.feature"],
  steps: ["shared.exs", "second.exs"],
  support: ["shared.exs", "second.exs"]
)

receive do
  :passed_gate -> :ok
after
  0 -> raise "compilation finished without passing through the gate"
end

%{total: 2, failures: 0} = ExUnit.await_run(runner)
