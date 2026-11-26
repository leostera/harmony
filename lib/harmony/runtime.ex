defmodule Harmony.Runtime do
  @moduledoc """
  Runs Harmony functions in the current BEAM.

  Objects load as ordinary modules named after their hash. A new release adds
  new modules next to the old ones instead of replacing them, so a live node
  can switch releases without purging code: calls already running keep using
  the old hashes, and the next call through the name table uses the new ones.
  """

  alias Harmony.{Object, Release, Store}

  @spec run(Path.t(), String.t(), binary(), pos_integer() | :head) ::
          {:ok, binary()} | {:error, String.t()}
  def run(store, name, input, release \\ :head) when is_binary(input) do
    with {:ok, release} <- Store.release(store, release),
         {:ok, hashes} <- Release.closure(release, name),
         {:ok, beams} <- Store.objects(store, hashes),
         :ok <- load(beams) do
      call(Map.fetch!(release.names, name), input)
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

  @spec call(String.t(), binary()) :: {:ok, binary()} | {:error, String.t()}
  def call(hash, input) do
    {:ok, Object.module(hash).run(input)}
  rescue
    error -> {:error, Exception.message(error)}
  end
end
