if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Cucumber.Install do
    @shortdoc "Installs Cucumber into your project"

    @moduledoc """
    Installs Cucumber into your Elixir project.

    This task performs the following setup:

    1. Adds `Cucumber.compile_features!()` to your `test/test_helper.exs`
    2. Adds `test_ignore_filters` to your `mix.exs` project configuration

    ## Usage

        mix igniter.install cucumber

    Or if Cucumber is already added as a dependency:

        mix cucumber.install
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        example: "mix cucumber.install"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> setup_test_helper()
      |> setup_mix_project()
    end

    defp setup_test_helper(igniter) do
      test_helper_path = "test/test_helper.exs"

      igniter
      |> Igniter.include_or_create_file(test_helper_path, """
      ExUnit.start()
      Cucumber.compile_features!()
      """)
      |> Igniter.update_elixir_file(test_helper_path, fn zipper ->
        case find_compile_features_call(zipper) do
          {:ok, _zipper} -> {:ok, zipper}
          :error -> add_compile_features_call(zipper)
        end
      end)
    end

    defp find_compile_features_call(zipper) do
      Igniter.Code.Common.move_to(zipper, fn z ->
        Igniter.Code.Function.function_call?(z, {Cucumber, :compile_features!}, 0)
      end)
    end

    defp add_compile_features_call(zipper) do
      case Igniter.Code.Common.move_to(zipper, fn z ->
             Igniter.Code.Function.function_call?(z, {ExUnit, :start}, [0, 1])
           end) do
        {:ok, zipper} ->
          code = quote do: Cucumber.compile_features!()

          {:ok,
           zipper
           |> Sourceror.Zipper.insert_right(code)
           |> Sourceror.Zipper.root()
           |> Sourceror.Zipper.zip()}

        :error ->
          code =
            quote do
              ExUnit.start()
              Cucumber.compile_features!()
            end

          {:ok,
           zipper
           |> Sourceror.Zipper.root()
           |> Sourceror.Zipper.zip()
           |> Sourceror.Zipper.append_child(code)}
      end
    end

    defp setup_mix_project(igniter) do
      test_ignore_filters =
        {:code,
         quote do
           [
             ~r/features\/step_definitions/,
             ~r/features\/support/
           ]
         end}

      Igniter.Project.MixProject.update(igniter, :project, [:test_ignore_filters], fn zipper ->
        case zipper do
          nil -> {:ok, test_ignore_filters}
          _existing -> {:ok, zipper}
        end
      end)
    end
  end
end
