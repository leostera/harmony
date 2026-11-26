defmodule Harmony.Release do
  @moduledoc """
  An immutable snapshot: which name points at which hash, and which hashes
  each object calls. It holds no code; the code lives in the object store.
  """

  alias Harmony.Codebase

  @enforce_keys [:number, :names, :dependencies]
  defstruct [:number, :names, :dependencies]

  @type t :: %__MODULE__{
          number: pos_integer(),
          names: %{String.t() => String.t()},
          dependencies: %{String.t() => [String.t()]}
        }

  @type changes :: %{
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()],
          renamed: [{from :: String.t(), to :: String.t()}]
        }

  @hash ~r/\A[0-9a-f]{64}\z/

  def from_codebase(number, %Codebase{} = codebase) do
    %__MODULE__{
      number: number,
      names: codebase.names,
      dependencies:
        Map.new(codebase.objects, fn {hash, object} -> {hash, object.dependencies} end)
    }
  end

  @doc "Hashes reachable from `name`."
  @spec closure(t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def closure(%__MODULE__{} = release, name) do
    case Map.fetch(release.names, name) do
      {:ok, hash} -> {:ok, walk(release.dependencies, [hash], MapSet.new())}
      :error -> {:error, "release #{release.number} has no function named #{name}"}
    end
  end

  defp walk(_graph, [], seen), do: seen |> MapSet.to_list() |> Enum.sort()

  defp walk(graph, [hash | rest], seen) do
    if MapSet.member?(seen, hash),
      do: walk(graph, rest, seen),
      else: walk(graph, Map.fetch!(graph, hash) ++ rest, MapSet.put(seen, hash))
  end

  @doc "What a release changed by name. A rename is a name that moved, not new code."
  @spec changes(t() | nil, t()) :: changes()
  def changes(nil, current),
    do: %{added: Map.keys(current.names) |> Enum.sort(), removed: [], changed: [], renamed: []}

  def changes(previous, current) do
    old = previous.names
    new = current.names
    gone = Map.keys(old) -- Map.keys(new)
    fresh = Map.keys(new) -- Map.keys(old)

    renamed =
      for from <- Enum.sort(gone),
          to <- Enum.sort(fresh),
          old[from] == new[to],
          do: {from, to}

    %{
      added: Enum.sort(fresh -- Enum.map(renamed, &elem(&1, 1))),
      removed: Enum.sort(gone -- Enum.map(renamed, &elem(&1, 0))),
      changed:
        for(name <- Map.keys(new), Map.has_key?(old, name), old[name] != new[name], do: name)
        |> Enum.sort(),
      renamed: renamed
    }
  end

  def encode(%__MODULE__{} = release) do
    %{
      "format" => "harmony.release.v1",
      "release" => release.number,
      "names" => release.names,
      "dependencies" => release.dependencies
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(json) do
    with %{
           "format" => "harmony.release.v1",
           "release" => number,
           "names" => names,
           "dependencies" => deps
         }
         when is_integer(number) and number > 0 and is_map(names) and is_map(deps) <-
           safe_decode(json),
         true <-
           Enum.all?(names, fn {name, hash} -> is_binary(name) and Map.has_key?(deps, hash) end),
         true <-
           Enum.all?(deps, fn {hash, callees} ->
             hash =~ @hash and is_list(callees) and Enum.all?(callees, &Map.has_key?(deps, &1))
           end) do
      {:ok, %__MODULE__{number: number, names: names, dependencies: deps}}
    else
      _ -> {:error, "invalid release manifest"}
    end
  end

  defp safe_decode(json) do
    :json.decode(json)
  rescue
    _ -> :error
  end
end
