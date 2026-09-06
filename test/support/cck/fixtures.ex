defmodule Cucumber.CckFixtures do
  @moduledoc "Offline provenance checks and the online CCK revision comparison."
  import ExUnit.Assertions

  @root "test/fixtures/cck"
  @manifest @root |> Path.join("upstream.json") |> File.read!() |> JSON.decode!()

  def manifest, do: @manifest

  def assert_local do
    files =
      @root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.reject(&(&1 in ["README.md", "upstream.json"]))
      |> Enum.sort()

    assert files == @manifest["files"] |> Map.keys() |> Enum.sort(), "fixture inventory changed"

    for {path, expected} <- @manifest["files"] do
      bytes = File.read!(Path.join(@root, path))

      actual =
        :crypto.hash(:sha, ["blob #{byte_size(bytes)}\0", bytes]) |> Base.encode16(case: :lower)

      assert actual == expected, "fixture differs from pinned upstream: #{path}"
    end
  end

  def assert_upstream(tree) do
    refute tree["truncated"], "GitHub returned a truncated tree"

    files =
      for %{"path" => "devkit/samples/" <> path, "type" => "blob", "sha" => sha} <- tree["tree"],
          into: %{},
          do: {path, sha}

    samples =
      files
      |> Map.keys()
      |> Enum.map(&(String.split(&1, "/") |> hd()))
      |> Enum.uniq()
      |> Enum.sort()

    assert samples == @manifest["samples"],
           "upstream sample inventory changed; review new/excluded samples"

    for {path, sha} <- @manifest["files"] do
      assert files[path] == sha, "upstream fixture changed: #{path}"
    end

    :ok
  end
end
