defmodule Harmony.Beam do
  @moduledoc """
  Reads functions out of BEAM files, from any BEAM language.

  Harmony works on the Erlang abstract code a BEAM file carries in its
  `debug_info` chunk. Elixir, Erlang and Gleam all write it, so one reader
  covers them all. It doesn't hash raw instructions: the compiler optimizes a
  whole module at once, so one function's instructions can change when a
  neighbour changes.

  Inputs can be `.beam` files, directories of them (such as `ebin`), or, for
  convenience, `.ex` and `.erl` sources, which are compiled to BEAM first.
  Library modules are read the same way, from the code path.
  """

  @typedoc "A module's functions as Erlang abstract code, with records expanded."
  @type code :: %{
          functions: %{{atom(), arity()} => [tuple()]},
          exports: MapSet.t({atom(), arity()}),
          imports: %{{atom(), arity()} => module()},
          native: boolean()
        }

  @type modules :: %{module() => code()}

  @spec read([Path.t()]) :: {:ok, modules()} | {:error, String.t()}
  def read(paths) do
    with {:ok, files} <- expand(paths),
         {:ok, beams} <- beams(files) do
      Enum.reduce_while(beams, {:ok, %{}}, fn {origin, beam}, {:ok, acc} ->
        case code(beam) do
          {:ok, module, _code} when is_map_key(acc, module) ->
            {:halt, {:error, "#{inspect(module)} is defined more than once (#{origin})"}}

          {:ok, module, code} ->
            {:cont, {:ok, Map.put(acc, module, code)}}

          {:error, reason} ->
            {:halt, {:error, "#{origin}: #{reason}"}}
        end
      end)
    end
  end

  @doc "Reads a module's code from a BEAM binary or file."
  @spec code(binary() | charlist()) :: {:ok, module(), code()} | {:error, String.t()}
  def code(beam) do
    case :beam_lib.chunks(beam, [:debug_info]) do
      # Elixir writes `:none` and Erlang `{:none, options}` when it was off.
      {:ok, {module, [debug_info: {:debug_info_v1, _backend, none}]}}
      when none == :none or elem(none, 0) == :none ->
        {:error, "#{inspect(module)} was compiled without debug_info"}

      {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} ->
        case backend.debug_info(:erlang_v1, module, data, []) do
          {:ok, forms} -> {:ok, module, from_forms(forms)}
          _ -> {:error, "#{inspect(module)} has no Erlang abstract code in its debug info"}
        end

      {:ok, {module, _}} ->
        {:error, "#{inspect(module)} was compiled without debug_info"}

      {:error, :beam_lib, _} ->
        {:error, "not a BEAM file"}
    end
  end

  defp from_forms(forms) do
    forms =
      if Enum.any?(forms, &match?({:attribute, _, :record, _}, &1)),
        do: :erl_expand_records.module(forms, []),
        else: forms

    %{
      functions:
        Map.new(for {:function, _, name, arity, clauses} <- forms, do: {{name, arity}, clauses}),
      exports:
        MapSet.new(for {:attribute, _, :export, exports} <- forms, export <- exports, do: export),
      imports:
        Map.new(
          for {:attribute, _, :import, {module, imports}} <- forms,
              import <- imports,
              do: {import, module}
        ),
      # Native code replaces these functions' bodies once the module loads.
      native:
        Enum.any?(
          forms,
          &match?({:attribute, _, attribute, _} when attribute in [:on_load, :nifs], &1)
        )
    }
  end

  @typedoc "Where a library module comes from."
  @type library ::
          {:ok, code(), md5 :: String.t()}
          | {:unhashable, md5 :: String.t(), reason :: String.t()}
          | :preloaded
          | :missing

  @doc """
  Every module on the code path, by name: its BEAM file, or `:preloaded` for
  modules built into the VM.
  """
  @spec available() :: %{module() => charlist() | :preloaded}
  def available do
    for {name, path, _loaded} <- :code.all_available(), into: %{} do
      {List.to_atom(name), if(is_list(path), do: path, else: :preloaded)}
    end
  end

  @doc "Reads a library module from the code path."
  @spec library(module(), %{module() => charlist() | :preloaded}) :: library()
  def library(module, available) do
    case Map.get(available, module, :missing) do
      :missing ->
        :missing

      :preloaded ->
        :preloaded

      path ->
        {:ok, {^module, md5}} = :beam_lib.md5(path)
        md5 = Base.encode16(md5, case: :lower)

        case code(path) do
          {:ok, ^module, %{native: true}} -> {:unhashable, md5, "is implemented natively"}
          {:ok, ^module, code} -> {:ok, code, md5}
          {:error, reason} -> {:unhashable, md5, reason}
        end
    end
  end

  defp expand(paths) do
    files =
      Enum.flat_map(paths, fn path ->
        if File.dir?(path),
          do: Path.wildcard(Path.join(path, "**/*.{beam,ex,erl}")),
          else: [path]
      end)

    cond do
      files == [] ->
        {:error, "no .beam, .ex or .erl files in #{Enum.join(paths, ", ")}"}

      missing = Enum.find(files, &(not File.regular?(&1))) ->
        {:error, "#{missing} does not exist"}

      true ->
        {:ok, files |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp beams(files) do
    groups = Enum.group_by(files, &Path.extname/1)

    with {:ok, erlang} <- compile_erlang(Map.get(groups, ".erl", [])),
         {:ok, elixir} <-
           with_loaded(erlang, fn -> compile_elixir(Map.get(groups, ".ex", [])) end) do
      loaded =
        for file <- Map.get(groups, ".beam", []),
            do: {Path.relative_to_cwd(file), File.read!(file)}

      case Map.drop(groups, [".ex", ".erl", ".beam"]) |> Map.values() |> List.flatten() do
        [] -> {:ok, loaded ++ elixir ++ erlang}
        [other | _] -> {:error, "#{other} is not a .beam, .ex or .erl file"}
      end
    end
  end

  defp compile_erlang(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case :compile.file(String.to_charlist(file), [:binary, :debug_info, :return_errors]) do
        {:ok, _module, beam} ->
          {:cont, {:ok, [{Path.relative_to_cwd(file), beam} | acc]}}

        {:ok, _module, beam, _warnings} ->
          {:cont, {:ok, [{Path.relative_to_cwd(file), beam} | acc]}}

        {:error, errors, _warnings} ->
          {:halt, {:error, format_erlang_errors(errors)}}
      end
    end)
  end

  # Elixir compiles into a scratch directory, and the modules are unloaded
  # right after, so compiling two versions of one module doesn't clash.
  defp compile_elixir([]), do: {:ok, []}

  defp compile_elixir(files) do
    out = Path.join(System.tmp_dir!(), "harmony-build-#{System.unique_integer([:positive])}")
    # Elixir 1.18 doesn't create the output directory itself.
    File.mkdir_p!(out)

    # Harmony reads debug info, and `mix test` turns it off by default.
    previous =
      Map.new([:ignore_module_conflict, :debug_info], &{&1, Code.get_compiler_option(&1)})

    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.put_compiler_option(:debug_info, true)

    try do
      case Kernel.ParallelCompiler.compile_to_path(files, out, return_diagnostics: true) do
        {:ok, modules, _warnings} ->
          Enum.each(modules, &unload/1)

          {:ok,
           for(
             module <- modules,
             do: {inspect(module), File.read!(Path.join(out, "#{module}.beam"))}
           )}

        {:error, errors, _warnings} ->
          {:error, Enum.map_join(errors, "\n", &format_diagnostic/1)}
      end
    after
      Enum.each(previous, fn {option, value} -> Code.put_compiler_option(option, value) end)
      File.rm_rf!(out)
    end
  end

  # Elixir checks remote calls at compile time, so Erlang modules from the
  # same inputs are loaded while Elixir compiles, then unloaded.
  defp with_loaded(beams, fun) do
    modules =
      for {origin, beam} <- beams do
        {:ok, {module, _}} = :beam_lib.chunks(beam, [])
        {:module, ^module} = :code.load_binary(module, String.to_charlist(origin), beam)
        module
      end

    try do
      fun.()
    after
      Enum.each(modules, &unload/1)
    end
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp format_diagnostic(%{file: file, position: position, message: message}),
    do: "#{Path.relative_to_cwd(file || "nofile")}:#{format_position(position)}: #{message}"

  defp format_position({line, column}), do: "#{line}:#{column}"
  defp format_position(line), do: "#{line}"

  defp format_erlang_errors(errors) do
    for {file, problems} <- errors, {location, module, description} <- problems do
      "#{Path.relative_to_cwd(List.to_string(file))}:#{format_position(location)}: #{module.format_error(description)}"
    end
    |> Enum.join("\n")
  end
end
