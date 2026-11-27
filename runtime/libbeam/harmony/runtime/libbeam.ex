defmodule Harmony.Runtime.Libbeam do
  @moduledoc """
  Runs a Harmony function in a fresh libbeam Isolate.

  Each call boots an Isolate, loads the function's closure, calls it, and
  reclaims the Isolate. Set `HARMONY_LIBBEAM_HOST` to the native host binary
  if it isn't in `libbeam_elixir`'s `priv/` directory.

  An Isolate holds only Harmony objects, so closures that call pinned library
  modules by name can't run in one; they're refused before booting.
  """

  alias Harmony.{Object, Release, Store}

  @spec run(Path.t(), String.t(), binary(), pos_integer() | :head) ::
          {:ok, binary()} | {:error, String.t()}
  def run(store, name, input, release \\ :head) do
    with {:ok, release} <- Store.release(store, release),
         {:ok, hashes} <- Release.closure(release, name),
         :ok <- no_pins(release, hashes, name),
         {:ok, beams} <- Store.objects(store, hashes),
         {:ok, engine} <- Libbeam.Engine.start(engine_options()) do
      try do
        in_isolate(engine, callees_first(beams, release), Map.fetch!(release.names, name), input)
      after
        _ = Libbeam.Engine.shutdown(engine)
      end
    else
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "libbeam host unavailable: #{inspect(reason)}"}
    end
  end

  defp in_isolate(engine, beams, hash, input) do
    with {:ok, isolate} <- Libbeam.Engine.create_isolate(engine) do
      try do
        # The port protocol takes at most 512 modules per load.
        with :ok <- load(isolate, beams) do
          Libbeam.Isolate.call(isolate, Atom.to_string(Object.module(hash)), "run", input)
        end
      after
        _ = Libbeam.Isolate.stop(isolate)
      end
    end
    |> case do
      {:ok, output} -> {:ok, output}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp no_pins(release, hashes, name) do
    case release
         |> Release.requirements(hashes)
         |> Enum.map(&elem(&1, 0))
         |> Enum.uniq()
         |> Enum.sort() do
      [] ->
        :ok

      modules ->
        {:error,
         "#{name} calls library modules by name (#{Enum.map_join(Enum.take(modules, 3), ", ", &inspect/1)}" <>
           "#{if length(modules) > 3, do: " and #{length(modules) - 3} more"}), " <>
           "which a libbeam Isolate doesn't have"}
    end
  end

  defp load(isolate, beams) do
    beams
    |> Enum.chunk_every(512)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Libbeam.Isolate.load_modules(isolate, chunk) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Callees before callers, so each batch's calls resolve to loaded modules.
  defp callees_first(beams, release) do
    {order, _} =
      Enum.reduce(Enum.sort(Map.keys(beams)), {[], MapSet.new()}, &visit(&1, &2, release))

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(beams, &1))
  end

  defp visit(hash, {order, seen}, release) do
    if MapSet.member?(seen, hash) do
      {order, seen}
    else
      {order, seen} =
        release.dependencies
        |> Map.fetch!(hash)
        |> Enum.reduce({order, MapSet.put(seen, hash)}, &visit(&1, &2, release))

      {[hash | order], seen}
    end
  end

  defp engine_options do
    case System.get_env("HARMONY_LIBBEAM_HOST") do
      nil -> []
      path -> [executable: path]
    end
  end
end
