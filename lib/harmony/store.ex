defmodule Harmony.Store do
  @moduledoc """
  An append-only directory of function objects and releases.

      <store>/objects/<hash>.beam   one compiled function, written once
      <store>/releases/<n>.json     names -> hashes, plus the dependency graph
      <store>/HEAD                  the current release number

  Deploying writes only the objects the store doesn't have yet, then a new
  release, then moves HEAD. A release never changes after it is written, so
  rolling back is just pointing HEAD at an older release.
  """

  alias Harmony.{Codebase, Object, Release}

  @type deploy_report :: %{
          release: pos_integer(),
          previous: pos_integer() | nil,
          new_objects: [String.t()],
          reused_objects: [String.t()],
          new_library_objects: non_neg_integer(),
          pinned: non_neg_integer(),
          bytes_written: non_neg_integer(),
          changes: Release.changes()
        }

  @spec deploy(Path.t(), Codebase.t()) :: {:ok, deploy_report()} | {:error, String.t()}
  def deploy(store, %Codebase{} = codebase) do
    with :ok <- File.mkdir_p(objects_dir(store)),
         :ok <- File.mkdir_p(releases_dir(store)),
         {:ok, previous} <- head(store),
         {:ok, written} <- write_objects(store, codebase) do
      number = (previous || 0) + 1
      release = Release.from_codebase(number, codebase)

      with {:ok, old} <- if(previous, do: release(store, previous), else: {:ok, nil}),
           :ok <- write_exclusive(release_path(store, number), Release.encode(release)),
           :ok <- set_head(store, number) do
        {new, reused} =
          Enum.split_with(Map.keys(codebase.objects) |> Enum.sort(), &(&1 in written))

        {:ok,
         %{
           release: number,
           previous: previous,
           new_objects: new,
           reused_objects: reused,
           new_library_objects: Enum.count(new, &library_only?(&1, codebase)),
           pinned: map_size(codebase.pinned),
           bytes_written: Enum.sum(Enum.map(new, &byte_size(codebase.objects[&1].beam))),
           changes: Release.changes(old, release)
         }}
      end
    end
  end

  defp library_only?(hash, codebase) do
    hash in Map.values(codebase.library) and hash not in Map.values(codebase.names)
  end

  @doc "Points HEAD at an existing release."
  @spec rollback(Path.t(), pos_integer()) :: :ok | {:error, String.t()}
  def rollback(store, number) do
    with {:ok, _release} <- release(store, number), do: set_head(store, number)
  end

  @spec head(Path.t()) :: {:ok, pos_integer() | nil} | {:error, String.t()}
  def head(store) do
    case File.read(Path.join(store, "HEAD")) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, "#{store}/HEAD is corrupt"}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, "cannot read #{store}/HEAD: #{:file.format_error(reason)}"}
    end
  end

  @spec releases(Path.t()) :: [pos_integer()]
  def releases(store) do
    case File.ls(releases_dir(store)) do
      {:ok, files} ->
        files
        |> Enum.flat_map(fn file ->
          case Integer.parse(Path.rootname(file)) do
            {n, ""} -> [n]
            _ -> []
          end
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @spec release(Path.t(), pos_integer() | :head) :: {:ok, Release.t()} | {:error, String.t()}
  def release(store, :head) do
    case head(store) do
      {:ok, nil} -> {:error, "nothing deployed to #{store} yet"}
      {:ok, number} -> release(store, number)
      error -> error
    end
  end

  def release(store, number) when is_integer(number) do
    case File.read(release_path(store, number)) do
      {:ok, json} -> Release.decode(json)
      {:error, :enoent} -> {:error, "release #{number} does not exist"}
      {:error, reason} -> {:error, "cannot read release #{number}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Reads and checks the BEAM for each hash: its module must be named after the hash."
  @spec objects(Path.t(), [String.t()]) :: {:ok, %{String.t() => binary()}} | {:error, String.t()}
  def objects(store, hashes) do
    Enum.reduce_while(hashes, {:ok, %{}}, fn hash, {:ok, acc} ->
      with {:ok, beam} <- File.read(object_path(store, hash)),
           {:ok, {module, _}} <- :beam_lib.chunks(beam, []),
           true <- module == Object.module(hash) do
        {:cont, {:ok, Map.put(acc, hash, beam)}}
      else
        _ -> {:halt, {:error, "object #{hash} is missing or corrupt"}}
      end
    end)
  end

  defp write_objects(store, codebase) do
    Enum.reduce_while(codebase.objects, {:ok, []}, fn {hash, object}, {:ok, written} ->
      path = object_path(store, hash)

      case File.read(path) do
        {:ok, existing} when existing == object.beam ->
          {:cont, {:ok, written}}

        {:ok, _different} ->
          {:halt, {:error, "#{path} exists with different bytes; the store is corrupt"}}

        {:error, :enoent} ->
          case write_exclusive(path, object.beam) do
            :ok -> {:cont, {:ok, [hash | written]}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp set_head(store, number) do
    temporary = Path.join(store, "HEAD.#{System.unique_integer([:positive])}")

    with :ok <- File.write(temporary, "#{number}\n"),
         :ok <- File.rename(temporary, Path.join(store, "HEAD")) do
      :ok
    else
      {:error, reason} -> {:error, "cannot update HEAD: #{:file.format_error(reason)}"}
    end
  end

  defp write_exclusive(path, bytes) do
    case File.write(path, bytes, [:exclusive, :binary]) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp objects_dir(store), do: Path.join(store, "objects")
  defp releases_dir(store), do: Path.join(store, "releases")
  defp object_path(store, hash), do: Path.join(objects_dir(store), hash <> ".beam")
  defp release_path(store, number), do: Path.join(releases_dir(store), "#{number}.json")
end
