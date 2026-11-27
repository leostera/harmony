defmodule Harmony.Object do
  @moduledoc """
  One content-addressed function and its compiled BEAM module.

  `dependencies` are the hashes it calls. `requires` are the library modules
  it calls by name (pinned), with the MD5 of the build it was hashed against.
  """

  @enforce_keys [:hash, :arity, :dependencies, :requires, :beam]
  defstruct [:hash, :arity, :dependencies, :requires, :beam]

  @type t :: %__MODULE__{
          hash: String.t(),
          arity: arity(),
          dependencies: [String.t()],
          requires: %{module() => md5 :: String.t()},
          beam: binary()
        }

  @spec module(String.t()) :: module()
  def module(hash), do: String.to_atom("harmony_" <> hash)

  @doc false
  def compile(hash, arity, clauses) do
    module = module(hash)

    forms = [
      {:attribute, 0, :module, module},
      {:attribute, 0, :export, [run: arity]},
      {:function, 0, :run, arity, clauses}
    ]

    case :compile.forms(forms, [:binary, :deterministic, :no_debug_info, :return_errors]) do
      {:ok, ^module, beam} -> beam
      {:ok, ^module, beam, _warnings} -> beam
      {:error, errors, _warnings} -> raise "could not compile #{hash}: #{inspect(errors)}"
    end
  end
end
