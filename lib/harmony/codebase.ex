defmodule Harmony.Codebase do
  @moduledoc """
  Turns BEAM functions into content-addressed objects.

  A function's hash covers its body as Erlang abstract code (after macro
  expansion, read from the BEAM file's debug info), with line
  numbers removed and variables renamed by position. Calls to your own
  functions are replaced by the callee's hash, so:

    * renaming a function, moving it to another module, or renaming a
      variable changes no hash;
    * changing a function changes its hash and the hash of every caller;
    * identical functions share one hash and one compiled object.

  Recursive groups are hashed together, as Unison does: members are ordered
  by their shape, and each member's hash is the group's hash plus its
  position in it.

  Each object compiles to one BEAM module named after its hash
  (`harmony_<hash>`) exporting `run/N`, so two versions never compete for a
  module name.

  ## The subset

  Harmony accepts any BEAM module with debug info, from Elixir, Erlang or
  Gleam, as long as:

    * it only calls your own modules and `:erlang` (the operators, guards and
      BIFs Elixir compiles to). Everything else, including `Enum`, `String`
      and interpolation of non-binaries, is outside the subset for now;
    * module names are only used to call functions: no structs, protocols,
      exceptions, `__MODULE__`, or `apply/3` with a module.
  """

  alias Harmony.{Beam, Object}

  @enforce_keys [:names, :objects]
  defstruct [:names, :objects]

  @type hash :: String.t()
  @type t :: %__MODULE__{names: %{String.t() => hash()}, objects: %{hash() => Object.t()}}

  # :erlang functions that take a module and function as data.
  @mfa_functions [
    apply: 3,
    spawn: 3,
    spawn: 4,
    spawn_link: 3,
    spawn_link: 4,
    spawn_monitor: 3,
    spawn_monitor: 4,
    spawn_opt: 4,
    spawn_opt: 5,
    make_fun: 3,
    function_exported: 3,
    hibernate: 3
  ]

  @doc "Reads `.beam` files or `ebin` directories (or `.ex`/`.erl` sources) and builds a codebase."
  @spec from_paths([Path.t()]) :: {:ok, t()} | {:error, String.t()}
  def from_paths(paths) do
    with {:ok, modules} <- Beam.read(paths), do: build(modules)
  end

  @spec build(Beam.functions()) :: {:ok, t()} | {:error, String.t()}
  def build(modules) do
    user_modules = MapSet.new(Map.keys(modules))

    functions =
      for {module, functions} <- modules,
          {name, arity, clauses} <- functions,
          own_function?(name),
          into: %{},
          do: {{module, name, arity}, clauses}

    with {:ok, analysed} <- analyse(functions, user_modules) do
      hashes =
        analysed
        |> components()
        |> Enum.reduce(%{}, &hash_component(&1, analysed, &2))

      objects =
        Map.new(analysed, fn {mfa, info} ->
          hash = hashes[mfa]

          dependencies =
            info.calls |> Enum.map(&hashes[&1]) |> Enum.uniq() |> Enum.sort()

          beam =
            Object.compile(hash, info.arity, substitute(info.shape, &compile_ref(&1, hashes)))

          {hash, %Object{hash: hash, arity: info.arity, dependencies: dependencies, beam: beam}}
        end)

      {:ok,
       %__MODULE__{names: Map.new(hashes, fn {mfa, h} -> {display(mfa), h} end), objects: objects}}
    end
  end

  @doc "`Greeter.main/1` for `{Greeter, :main, 1}`."
  def display({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"

  # Elixir-generated reflection; it names the module, and nothing calls it.
  defp own_function?(:__info__), do: false
  defp own_function?(:module_info), do: false
  defp own_function?(name), do: not String.starts_with?(Atom.to_string(name), "MACRO-")

  ## Checking the subset and marking calls to your own functions

  defp analyse(functions, user_modules) do
    Enum.reduce_while(functions, {:ok, %{}}, fn {{module, _, arity} = mfa, clauses}, {:ok, acc} ->
      context = %{module: module, user_modules: user_modules, defined: functions}

      try do
        # Objects compile from this same normalized code, so an object's bytes
        # depend only on its hash. (Stack traces lose line numbers as a result.)
        # Annotations go first: erl_parse only knows standard forms.
        shape = clauses |> strip_annotations(arity) |> mark(context) |> canonical_variables()
        calls = calls(shape)

        case Enum.find(calls, &(not Map.has_key?(functions, &1))) do
          nil ->
            {:cont, {:ok, Map.put(acc, mfa, %{arity: arity, shape: shape, calls: calls})}}

          missing ->
            {:halt, {:error, "#{display(mfa)} calls #{display(missing)}, which isn't defined"}}
        end
      catch
        {:harmony, reason} -> {:halt, {:error, "#{display(mfa)} #{reason}"}}
      end
    end)
  end

  defp mark({:call, anno, {:remote, _, {:atom, _, module}, {:atom, _, name}}, args}, context) do
    arity = length(args)

    cond do
      MapSet.member?(context.user_modules, module) ->
        {:call, anno, {:harmony_ref, {module, name, arity}}, mark(args, context)}

      module == :erlang and {name, arity} in @mfa_functions ->
        throw({:harmony, "calls :erlang.#{name}/#{arity}, which takes a module as data"})

      module == :erlang ->
        {:call, anno, {:remote, anno, {:atom, anno, :erlang}, {:atom, anno, name}},
         mark(args, context)}

      true ->
        throw({:harmony, "calls #{inspect(module)}.#{name}/#{arity}" <> outside_hint(module)})
    end
  end

  defp mark({:call, _, {:remote, _, _, _}, _}, _context),
    do: throw({:harmony, "calls a function on a module chosen at runtime"})

  # Erlang writes calls to auto-imported BIFs (`is_integer(X)`) as local calls.
  defp mark({:call, anno, {:atom, _, name}, args}, context) do
    mfa = {context.module, name, length(args)}

    if not Map.has_key?(context.defined, mfa) and :erl_internal.bif(name, length(args)),
      do:
        {:call, anno, {:remote, anno, {:atom, anno, :erlang}, {:atom, anno, name}},
         mark(args, context)},
      else: {:call, anno, {:harmony_ref, mfa}, mark(args, context)}
  end

  defp mark({:fun, anno, {:function, name, arity}}, context) when is_atom(name),
    do: {:harmony_fun, anno, {context.module, name, arity}}

  defp mark(
         {:fun, anno, {:function, {:atom, _, module}, {:atom, _, name}, {:integer, _, arity}}} =
           fun,
         context
       ) do
    cond do
      MapSet.member?(context.user_modules, module) ->
        {:harmony_fun, anno, {module, name, arity}}

      module == :erlang ->
        fun

      true ->
        throw({:harmony, "captures #{inspect(module)}.#{name}/#{arity}" <> outside_hint(module)})
    end
  end

  defp mark({:fun, _, {:function, _, _, _}}, _context),
    do: throw({:harmony, "captures a function on a module chosen at runtime"})

  defp mark({:atom, _, atom} = term, context) do
    if MapSet.member?(context.user_modules, atom),
      do:
        throw(
          {:harmony,
           "uses the module #{inspect(atom)} as a value (structs, protocols, exceptions, " <>
             "__MODULE__ and apply/3 aren't supported); module names can only be used to call functions"}
        ),
      else: term
  end

  defp mark(tuple, context) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&mark(&1, context)) |> List.to_tuple()

  defp mark(list, context) when is_list(list), do: Enum.map(list, &mark(&1, context))
  defp mark(other, _context), do: other

  defp outside_hint(String.Chars),
    do: ", which is outside Harmony's subset (interpolate binaries only, or use <>)"

  defp outside_hint(_module),
    do: ", which is outside Harmony's subset (only your modules and :erlang can be called)"

  defp calls(term) do
    term
    |> collect([])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect({:harmony_ref, mfa}, acc), do: [mfa | acc]
  defp collect({:harmony_fun, _, mfa}, acc), do: [mfa | acc]
  defp collect(tuple, acc) when is_tuple(tuple), do: collect(Tuple.to_list(tuple), acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_other, acc), do: acc

  ## Normalizing a function's shape for hashing

  # Annotations hold line and column numbers. erl_parse knows where they are,
  # so we strip them from a whole function form before reading its clauses back.
  defp strip_annotations(clauses, arity) do
    :erl_parse.map_anno(fn _ -> 0 end, {:function, 0, :f, arity, clauses}) |> elem(4)
  end

  # Elixir names variables `name@1`; renaming them by first use makes the hash
  # ignore variable names.
  defp canonical_variables(clauses) do
    {clauses, _} = rename(clauses, %{})
    clauses
  end

  defp rename({:var, anno, :_}, names), do: {{:var, anno, :_}, names}

  defp rename({:var, anno, name}, names) do
    case names do
      %{^name => canonical} -> {{:var, anno, canonical}, names}
      _ -> rename({:var, anno, name}, Map.put(names, name, :"V#{map_size(names)}"))
    end
  end

  defp rename(tuple, names) when is_tuple(tuple) do
    {elements, names} = rename(Tuple.to_list(tuple), names)
    {List.to_tuple(elements), names}
  end

  defp rename(list, names) when is_list(list), do: Enum.map_reduce(list, names, &rename/2)
  defp rename(other, names), do: {other, names}

  ## Recursive groups, callees first

  defp components(analysed) do
    graph = :digraph.new()

    try do
      for mfa <- Map.keys(analysed), do: :digraph.add_vertex(graph, mfa)
      for {mfa, info} <- analysed, callee <- info.calls, do: :digraph.add_edge(graph, mfa, callee)
      condensed = :digraph_utils.condensation(graph)

      try do
        condensed |> :digraph_utils.topsort() |> Enum.reverse()
      after
        :digraph.delete(condensed)
      end
    after
      :digraph.delete(graph)
    end
  end

  defp hash_component(members, analysed, hashes) do
    in_group = MapSet.new(members)

    # Order members by their shape with calls inside the group blanked out.
    # Names only break ties between members that look exactly alike.
    ordered =
      members
      |> Enum.map(fn mfa ->
        blank =
          shape(
            mfa,
            analysed,
            &if(MapSet.member?(in_group, &1), do: :recursive, else: {:hash, hashes[&1]})
          )

        {digest(blank), mfa}
      end)
      |> Enum.sort_by(fn {key, {m, f, a}} -> {key, Atom.to_string(m), Atom.to_string(f), a} end)
      |> Enum.map(&elem(&1, 1))

    position = ordered |> Enum.with_index() |> Map.new()

    group =
      Enum.map(ordered, fn mfa ->
        shape(
          mfa,
          analysed,
          &if(Map.has_key?(position, &1), do: {:self, position[&1]}, else: {:hash, hashes[&1]})
        )
      end)

    Enum.reduce(ordered, hashes, fn mfa, hashes ->
      Map.put(hashes, mfa, digest({:harmony_function_v1, group, position[mfa]}))
    end)
  end

  defp shape(mfa, analysed, reference) do
    info = Map.fetch!(analysed, mfa)
    {info.arity, substitute(info.shape, &shape_ref(&1, reference))}
  end

  defp shape_ref({:call, mfa}, reference), do: {:ref, reference.(mfa)}
  defp shape_ref({:fun, _anno, mfa}, reference), do: {:fun_ref, reference.(mfa)}

  defp compile_ref({:call, mfa}, hashes),
    do: {:remote, 0, {:atom, 0, Object.module(hashes[mfa])}, {:atom, 0, :run}}

  defp compile_ref({:fun, anno, {_, _, arity} = mfa}, hashes),
    do:
      {:fun, anno,
       {:function, {:atom, anno, Object.module(hashes[mfa])}, {:atom, anno, :run},
        {:integer, anno, arity}}}

  defp substitute({:harmony_ref, mfa}, replace), do: replace.({:call, mfa})
  defp substitute({:harmony_fun, anno, mfa}, replace), do: replace.({:fun, anno, mfa})

  defp substitute(tuple, replace) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&substitute(&1, replace)) |> List.to_tuple()

  defp substitute(list, replace) when is_list(list), do: Enum.map(list, &substitute(&1, replace))
  defp substitute(other, _replace), do: other

  defp digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic, minor_version: 2]))
    |> Base.encode16(case: :lower)
  end
end
