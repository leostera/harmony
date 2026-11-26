defmodule Harmony.Runtime do
  @moduledoc """
  Runs Harmony functions in the current BEAM.

  Objects load as ordinary modules named after their hash. A new release adds
  new modules next to the old ones instead of replacing them, so a live node
  can switch releases without purging code: calls already running keep using
  the old hashes, and the next call through the name table uses the new ones.
  """

  alias Harmony.{Object, Release, Store}

  @doc "Calls `name` (such as `Greeter.main/1`) with `args` from a release."
  @spec run(Path.t(), String.t(), [term()], pos_integer() | :head) ::
          {:ok, term()} | {:error, String.t()}
  def run(store, name, args, release \\ :head) when is_list(args) do
    with {:ok, release} <- Store.release(store, release),
         {:ok, hashes} <- Release.closure(release, name),
         {:ok, beams} <- Store.objects(store, hashes),
         :ok <- load(beams) do
      call(Map.fetch!(release.names, name), args)
    end
  end

  @doc "Loads objects that aren't loaded yet. A hash-named module never needs replacing."
  @spec load(%{String.t() => binary()}) :: :ok | {:error, String.t()}
  def load(beams) do
    Enum.reduce_while(beams, :ok, fn {hash, beam}, :ok ->
      module = Object.module(hash)

      cond do
        :code.is_loaded(module) != false ->
          {:cont, :ok}

        match?({:module, ^module}, :code.load_binary(module, ~c"harmony:#{hash}", beam)) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, "could not load object #{hash}"}}
      end
    end)
  end

  @spec call(String.t(), [term()]) :: {:ok, term()} | {:error, String.t()}
  def call(hash, args) when is_list(args) do
    {:ok, apply(Object.module(hash), :run, args)}
  rescue
    error -> {:error, Exception.message(error)}
  end
end
