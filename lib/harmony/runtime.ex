defmodule Harmony.Runtime do
  @moduledoc """
  Runs Harmony functions in the current BEAM.

  Objects load as ordinary modules named after their hash. A new release adds
  new modules next to the old ones instead of replacing them, so a live node
  can switch releases without purging code: calls already running keep using
  the old hashes, and the next call through the name table uses the new ones.

  Library functions Harmony couldn't hash are called by name, so before
  loading, the runtime checks that this VM has the exact build of each such
  module the release was hashed against.
  """

  alias Harmony.{Object, Release, Store}

  @doc "Calls `name` (such as `Greeter.main/1`) with `args` from a release."
  @spec run(Path.t(), String.t(), [term()], pos_integer() | :head) ::
          {:ok, term()} | {:error, String.t()}
  def run(store, name, args, release \\ :head) when is_list(args) do
    with {:ok, release} <- Store.release(store, release),
         {:ok, hashes} <- Release.closure(release, name),
         :ok <- check(Release.requirements(release, hashes)),
         {:ok, beams} <- Store.objects(store, hashes),
         :ok <- load(beams) do
      call(Map.fetch!(release.names, name), args)
    end
  end

  @doc "Checks this VM has each library module at the MD5 the release was built against."
  @spec check([{module(), String.t()}]) :: :ok | {:error, String.t()}
  def check(requirements) do
    Enum.find_value(Enum.sort(requirements), :ok, fn {module, md5} ->
      with {:module, ^module} <- Code.ensure_loaded(module),
           ^md5 <- Base.encode16(module.module_info(:md5), case: :lower) do
        nil
      else
        {:error, _} ->
          {:error, "this release calls #{inspect(module)}, which this VM doesn't have"}

        other ->
          {:error,
           "this release was built against #{inspect(module)} #{String.slice(md5, 0, 10)}, " <>
             "but this VM has #{String.slice(other, 0, 10)}; deploy again from this VM"}
      end
    end)
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
