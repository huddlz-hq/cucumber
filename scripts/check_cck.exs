# MIX_ENV=test mix run scripts/check_cck.exs [upstream-revision]
# No argument verifies provenance at the pinned revision. Pass main to detect drift.
manifest = Cucumber.CckFixtures.manifest()
revision = List.first(System.argv()) || manifest["revision"]
Cucumber.CckFixtures.assert_local()
endpoint = "repos/#{manifest["repository"]}/git/trees/#{revision}?recursive=1"

case System.cmd("gh", ["api", endpoint], stderr_to_stdout: true) do
  {json, 0} ->
    json |> JSON.decode!() |> Cucumber.CckFixtures.assert_upstream()
    IO.puts("CCK fixtures and sample inventory match #{revision}")

  {error, status} ->
    raise "GitHub tree lookup failed (#{status}): #{error}"
end
