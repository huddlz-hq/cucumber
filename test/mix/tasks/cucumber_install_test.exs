defmodule Mix.Tasks.Cucumber.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Igniter.Project.MixProject

  test "installs into a new project and is idempotent" do
    installed =
      test_project()
      |> Igniter.compose_task("cucumber.install")
      |> apply_igniter!()

    assert_content_equals(installed, "test/test_helper.exs", """
    ExUnit.start()
    Cucumber.compile_features!()
    """)

    assert installed.assigns.test_files["mix.exs"] =~ "~r/features\\/step_definitions/"
    assert installed.assigns.test_files["mix.exs"] =~ "~r/features\\/support/"

    installed
    |> Igniter.compose_task("cucumber.install")
    |> assert_unchanged()
  end

  test "preserves helper setup and existing ignore filters" do
    helper = """
    Application.put_env(:example, :enabled, true)
    ExUnit.start(exclude: [:integration])
    IO.puts("test setup")
    """

    test_project(files: %{"test/test_helper.exs" => helper})
    |> MixProject.update(:project, [:test_ignore_filters], fn _ ->
      {:ok, {:code, quote(do: [~r/custom_support/])}}
    end)
    |> apply_igniter!()
    |> Igniter.compose_task("cucumber.install")
    |> assert_unchanged("mix.exs")
    |> assert_content_equals("test/test_helper.exs", """
    Application.put_env(:example, :enabled, true)
    ExUnit.start(exclude: [:integration])
    Cucumber.compile_features!()
    IO.puts("test setup")
    """)
    |> apply_igniter!()
  end

  test "creates a missing test helper" do
    test_project()
    |> Igniter.rm("test/test_helper.exs")
    |> apply_igniter!()
    |> Igniter.compose_task("cucumber.install")
    |> assert_creates("test/test_helper.exs", """
    ExUnit.start()
    Cucumber.compile_features!()
    """)
    |> apply_igniter!()
  end

  test "adds startup calls after existing code when ExUnit.start is absent" do
    test_project(files: %{"test/test_helper.exs" => "Application.ensure_all_started(:logger)"})
    |> Igniter.compose_task("cucumber.install")
    |> assert_content_equals("test/test_helper.exs", """
    Application.ensure_all_started(:logger)
    ExUnit.start()
    Cucumber.compile_features!()
    """)
    |> apply_igniter!()
  end
end
