defmodule Cucumber.CckFixturesTest do
  use ExUnit.Case, async: true

  test "authoritative schema bundle remains unchanged" do
    digest =
      "test/fixtures/messages/messages.schema.json"
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert digest == "f38d9465faaa2920290f6d659fd88f8aa02e3789473a97a08625aab49d285d62"
  end

  test "vendored fixtures match the pinned upstream Git blobs" do
    Cucumber.CckFixtures.assert_local()
  end

  test "upstream comparison detects added samples and changed blobs" do
    manifest = Cucumber.CckFixtures.manifest()

    tree =
      for {path, sha} <- manifest["files"],
          do: %{"path" => "devkit/samples/" <> path, "sha" => sha, "type" => "blob"}

    missing =
      manifest["samples"] --
        Enum.map(Map.keys(manifest["files"]), &(String.split(&1, "/") |> hd()))

    tree =
      tree ++
        Enum.map(
          missing,
          &%{"path" => "devkit/samples/#{&1}/README.md", "sha" => "unused", "type" => "blob"}
        )

    assert :ok = Cucumber.CckFixtures.assert_upstream(%{"tree" => tree, "truncated" => false})

    for bad <- [
          [
            %{"path" => "devkit/samples/new/new.feature", "type" => "blob", "sha" => "new"} | tree
          ],
          tl(tree),
          [Map.put(hd(tree), "sha", "changed") | tl(tree)]
        ] do
      assert_raise ExUnit.AssertionError, fn ->
        Cucumber.CckFixtures.assert_upstream(%{"tree" => bad, "truncated" => false})
      end
    end
  end
end
