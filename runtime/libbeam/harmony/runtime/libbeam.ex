defmodule Harmony.Runtime.Libbeam do
  @moduledoc """
  Runs a Harmony function in a fresh libbeam Isolate.

  Each call boots an Isolate, loads the function's closure, calls it, and
  reclaims the Isolate. Set `HARMONY_LIBBEAM_HOST` to the native host binary
  if it isn't in `libbeam_elixir`'s `priv/` directory.
  """

  alias Harmony.{Object, Release, Store}

  @spec run(Path.t(), String.t(), binary(), pos_integer() | :head) ::
          {:ok, binary()} | {:error, String.t()}
  def run(store, name, input, release \\ :head) do
    with {:ok, release} <- Store.release(store, release),
         {:ok, hashes} <- Release.closure(release, name),
         {:ok, beams} <- Store.objects(store, hashes),
         {:ok, engine} <- Libbeam.Engine.start(engine_options()) do
      try do
        in_isolate(engine, beams, Map.fetch!(release.names, name), input)
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
        with :ok <- Libbeam.Isolate.load_modules(isolate, Map.values(beams)) do
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

  defp engine_options do
    case System.get_env("HARMONY_LIBBEAM_HOST") do
      nil -> []
      path -> [executable: path]
    end
  end
end
