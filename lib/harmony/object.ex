defmodule Harmony.Object do
  @moduledoc "One content-addressed function and its compiled BEAM module."

  @enforce_keys [:hash, :body, :dependencies, :beam]
  defstruct [:hash, :body, :dependencies, :beam]

  @type t :: %__MODULE__{
          hash: String.t(),
          body: term(),
          dependencies: [String.t()],
          beam: binary()
        }

  @spec module(String.t()) :: module()
  def module(hash), do: String.to_atom("harmony_" <> hash)

  @doc false
  def compile(hash, body) do
    module = module(hash)

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [run: 1]},
      {:function, 1, :run, 1, [{:clause, 1, [{:var, 1, :Input}], [], [expression(body)]}]}
    ]

    {:ok, ^module, beam} = :compile.forms(forms, [:binary, :deterministic, :no_debug_info])
    beam
  end

  defp expression(:input), do: {:var, 1, :Input}
  defp expression({:literal, bytes}), do: :erl_parse.abstract(bytes)

  defp expression({:call, hash, argument}),
    do:
      {:call, 1, {:remote, 1, {:atom, 1, module(hash)}, {:atom, 1, :run}}, [expression(argument)]}

  defp expression({:concat, parts}),
    do: {:bin, 1, Enum.map(parts, &{:bin_element, 1, expression(&1), :default, [:binary]})}
end
