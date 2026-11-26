defmodule Harmony.Codebase do
  @moduledoc """
  Turns named definitions into content-addressed function objects.

  A function's hash covers its body only. Calls inside the body refer to the
  callee's hash, never its name, so:

    * renaming a function changes nothing but the name table;
    * changing a function changes its hash and the hash of every caller;
    * two identical definitions share one hash and one compiled object.

  Each object compiles to one BEAM module named after its hash
  (`harmony_<hash>`) that exports `run/1`. Because a module name is derived
  from content, two different versions never compete for the same module name.
  """

  alias Harmony.{Object, Syntax}

  @enforce_keys [:names, :objects]
  defstruct [:names, :objects]

  @type hash :: String.t()
  @type t :: %__MODULE__{names: %{String.t() => hash()}, objects: %{hash() => Object.t()}}

  @hash_domain "harmony.function.v1"

  @spec from_source(String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_source(source) do
    with {:ok, definitions} <- Syntax.parse(source), do: build(definitions)
  end

  @spec build(Syntax.definitions()) :: {:ok, t()} | {:error, String.t()}
  def build(definitions) when is_map(definitions) do
    names = definitions |> Map.keys() |> Enum.sort()

    result =
      Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, resolved} ->
        case resolve(name, definitions, resolved, []) do
          {:ok, resolved} -> {:cont, {:ok, resolved}}
          error -> {:halt, error}
        end
      end)

    with {:ok, resolved} <- result do
      objects = resolved |> Map.values() |> Map.new(&{&1.hash, &1})
      names = Map.new(resolved, fn {name, object} -> {name, object.hash} end)
      {:ok, %__MODULE__{names: names, objects: objects}}
    end
  end

  @doc "Hashes reachable from `name`, including its own."
  @spec closure(t(), String.t()) :: {:ok, [hash()]} | {:error, String.t()}
  def closure(%__MODULE__{} = codebase, name) do
    case Map.fetch(codebase.names, name) do
      {:ok, hash} -> {:ok, codebase.objects |> walk([hash], MapSet.new()) |> Enum.sort()}
      :error -> {:error, "no function named #{name}"}
    end
  end

  defp walk(_objects, [], seen), do: MapSet.to_list(seen)

  defp walk(objects, [hash | rest], seen) do
    if MapSet.member?(seen, hash),
      do: walk(objects, rest, seen),
      else: walk(objects, Map.fetch!(objects, hash).dependencies ++ rest, MapSet.put(seen, hash))
  end

  defp resolve(name, definitions, resolved, stack) do
    cond do
      Map.has_key?(resolved, name) ->
        {:ok, resolved}

      name in stack ->
        cycle = Enum.reverse([name | stack]) |> Enum.join(" -> ")
        {:error, "recursion is not supported yet: #{cycle}"}

      not Map.has_key?(definitions, name) ->
        caller = List.first(stack)
        {:error, "#{caller} calls #{name}, which is not defined"}

      true ->
        with {:ok, body, resolved} <-
               normalize(Map.fetch!(definitions, name), definitions, resolved, [name | stack]) do
          {:ok, Map.put(resolved, name, object(body))}
        end
    end
  end

  # Replaces every callee name with that callee's object, resolving it first.
  defp normalize(:input, _definitions, resolved, _stack), do: {:ok, :input, resolved}

  defp normalize({:literal, bytes} = literal, _definitions, resolved, _stack)
       when is_binary(bytes),
       do: {:ok, literal, resolved}

  defp normalize({:call, callee, argument}, definitions, resolved, stack) do
    with {:ok, resolved} <- resolve(callee, definitions, resolved, stack),
         {:ok, argument, resolved} <- normalize(argument, definitions, resolved, stack) do
      {:ok, {:call, Map.fetch!(resolved, callee).hash, argument}, resolved}
    end
  end

  defp normalize({:concat, parts}, definitions, resolved, stack) do
    Enum.reduce_while(parts, {:ok, [], resolved}, fn part, {:ok, done, resolved} ->
      case normalize(part, definitions, resolved, stack) do
        {:ok, part, resolved} -> {:cont, {:ok, [part | done], resolved}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts, resolved} -> {:ok, {:concat, Enum.reverse(parts)}, resolved}
      error -> error
    end
  end

  defp object(body) do
    hash = :crypto.hash(:sha256, @hash_domain <> encode(body)) |> Base.encode16(case: :lower)

    %Object{
      hash: hash,
      body: body,
      dependencies: dependencies(body),
      beam: Object.compile(hash, body)
    }
  end

  # A canonical, versioned byte encoding, so hashes don't depend on the
  # Erlang term format or the compiler.
  defp encode(:input), do: <<0>>
  defp encode({:literal, bytes}), do: <<1, byte_size(bytes)::32, bytes::binary>>

  defp encode({:call, hash, argument}),
    do: <<2, Base.decode16!(hash, case: :lower)::binary, encode(argument)::binary>>

  defp encode({:concat, parts}), do: <<3, length(parts)::16>> <> Enum.map_join(parts, &encode/1)

  defp dependencies(body), do: body |> callees() |> Enum.uniq() |> Enum.sort()

  defp callees({:call, hash, argument}), do: [hash | callees(argument)]
  defp callees({:concat, parts}), do: Enum.flat_map(parts, &callees/1)
  defp callees(_), do: []
end
