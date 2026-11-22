# A fresh VM is needed to exercise the very first after_suite registration.
[tmp_dir] = System.argv()
File.cd!(__DIR__)
ExUnit.start(autorun: false)
Process.register(self(), CompileRuns.Driver)
Application.put_env(:cucumber, :messages, Path.join(tmp_dir, "empty.ndjson"))
[] = Cucumber.compile_features!(features: [], steps: [], support: [])
%{total: 0} = ExUnit.run()

Application.put_env(:cucumber, :messages, Path.join(tmp_dir, "joined.ndjson"))
runner = ExUnit.async_run()

Cucumber.compile_features!(features: "first.feature", steps: "shared.exs", support: "shared.exs")

receive do
  :first_recorded -> :ok
after
  5_000 -> raise "first scenario did not record its attachment"
end

Cucumber.compile_features!(
  features: "second.feature",
  steps: ["shared.exs", "second.exs"],
  support: ["shared.exs", "second.exs"]
)

%{total: 2, failures: 0} = ExUnit.await_run(runner)
