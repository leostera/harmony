defmodule Harmony.Codebase do
  @moduledoc """
  Turns BEAM functions into content-addressed objects.

  A function's hash covers its body as Erlang abstract code (after macro
  expansion, read from the BEAM file's debug info), with line numbers removed
  and variables renamed by position. Calls are replaced by the callee's hash,
  so:

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

  ## Libraries

  Calls into code outside the inputs (Elixir, OTP, your dependencies) reach
  one of three kinds of function:

    * **hashed**: library functions that follow the same rules as your code
      are read from the code path and hashed like it, callees first;
    * **primitive**: built-in functions of any module, and modules preloaded
      into the VM, are called as they are. They are the VM;
    * **pinned**: library functions Harmony can't hash (protocol dispatch,
      NIFs, a module chosen at runtime) are called by name. The caller's hash
      covers the MD5 of the pinned function's module, and the runtime refuses
      to run on a VM whose module differs.

  A library module named as data, such as an exception's struct name, is
  pinned the same way.

  ## The subset

  Your code is any BEAM module with debug info, from Elixir, Erlang or Gleam,
  as long as:

    * every call goes to a function that exists, by name;
    * your module names are only used to call functions: no structs,
      protocols, exceptions, `__MODULE__`, or `apply/3` with a module.
  """

  alias Harmony.{Beam, Object}

  @enforce_keys [:names, :objects, :library, :pinned]
  defstruct [:names, :objects, :library, :pinned]

  @type hash :: String.t()
  @type t :: %__MODULE__{
          names: %{String.t() => hash()},
          objects: %{hash() => Object.t()},
          library: %{String.t() => hash()},
          pinned: %{String.t() => String.t()}
        }

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

  @spec build(Beam.modules()) :: {:ok, t()} | {:error, String.t()}
  def build(modules) do
    state = %{
      user: modules,
      available: Beam.available(),
      libraries: %{},
      analysed: %{},
      unhashable: %{}
    }

    roots =
      for {module, code} <- modules,
          {name, arity} <- Map.keys(code.functions),
          own_function?(name),
          do: {module, name, arity}

    with {:ok, state} <- analyse_user(Enum.sort(roots), state) do
      state = discover(state)

      with {:ok, status} <- resolve(roots, state) do
        {:ok, objects(roots, status, state)}
      end
    end
  end

  @doc "`Greeter.main/1` for `{Greeter, :main, 1}`."
  def display({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"

  # Elixir-generated reflection; it names the module, and nothing calls it.
  defp own_function?(:__info__), do: false
  defp own_function?(:module_info), do: false
  defp own_function?(name), do: not String.starts_with?(Atom.to_string(name), "MACRO-")

  ## Reading functions: your code must fit, library code is hashed if it fits

  defp analyse_user(roots, state) do
    Enum.reduce_while(roots, {:ok, state}, fn {module, name, arity} = mfa, {:ok, state} ->
      code = Map.fetch!(state.user, module)

      case analyse(mfa, code.functions[{name, arity}], code, :user, state) do
        {:ok, info, state} ->
          {:cont, {:ok, %{state | analysed: Map.put(state.analysed, mfa, info)}}}

        {:error, reason, _state} ->
          {:halt, {:error, "#{display(mfa)} #{reason}"}}
      end
    end)
  end

  # Reads every library function reachable from what's been analysed so far.
  defp discover(state) do
    pending =
      for {_mfa, info} <- state.analysed,
          {module, _, _} = callee <- info.calls,
          not Map.has_key?(state.user, module),
          not Map.has_key?(state.analysed, callee),
          not Map.has_key?(state.unhashable, callee),
          uniq: true,
          do: callee

    if pending == [],
      do: state,
      else: pending |> Enum.reduce(state, &discover_one/2) |> discover()
  end

  defp discover_one({module, name, arity} = mfa, state) do
    {library, state} = library(module, state)

    case library do
      {:ok, code, _md5} ->
        case code.functions do
          %{{^name, ^arity} => clauses} ->
            case analyse(mfa, clauses, code, :library, state) do
              {:ok, info, state} ->
                %{state | analysed: Map.put(state.analysed, mfa, info)}

              {:error, reason, state} ->
                %{state | unhashable: Map.put(state.unhashable, mfa, reason)}
            end

          _ ->
            %{state | unhashable: Map.put(state.unhashable, mfa, :missing)}
        end

      {:unhashable, _md5, reason} ->
        %{state | unhashable: Map.put(state.unhashable, mfa, reason)}

      :missing ->
        %{state | unhashable: Map.put(state.unhashable, mfa, :missing)}
    end
  end

  defp library(module, state) do
    case state.libraries do
      %{^module => library} ->
        {library, state}

      _ ->
        library = Beam.library(module, state.available)
        {library, %{state | libraries: Map.put(state.libraries, module, library)}}
    end
  end

  defp analyse({module, _, arity}, clauses, code, origin, state) do
    context = %{module: module, code: code, user: state.user, available: state.available}

    try do
      # Objects compile from this same normalized code, so an object's bytes
      # depend only on its hash. (Stack traces lose line numbers as a result.)
      # Annotations go first: erl_parse only knows standard forms.
      shape = clauses |> strip_annotations(arity) |> mark(context) |> canonical_variables()

      {modules, state} =
        shape
        |> atoms()
        |> Enum.reduce({[], state}, fn atom, {modules, state} ->
          case named_module(atom, origin, state) do
            {:data, state} -> {modules, state}
            {{:module, md5}, state} -> {[{atom, md5} | modules], state}
          end
        end)

      {:ok, %{arity: arity, shape: shape, calls: calls(shape), named: Map.new(modules)}, state}
    catch
      {:harmony, reason} -> {:error, reason, state}
    end
  end

  # Your modules can't be data: their functions live in hash-named modules.
  # A library module named as data is pinned, since code may call it later.
  defp named_module(atom, origin, state) do
    cond do
      Map.has_key?(state.user, atom) and origin == :user ->
        throw(
          {:harmony,
           "uses the module #{inspect(atom)} as a value (structs, protocols, exceptions, " <>
             "__MODULE__ and apply/3 aren't supported); your module names can only be used to call functions"}
        )

      Map.has_key?(state.user, atom) or not Map.has_key?(state.available, atom) ->
        {:data, state}

      true ->
        case library(atom, state) do
          {{:ok, _code, md5}, state} -> {{:module, md5}, state}
          {{:unhashable, md5, _reason}, state} -> {{:module, md5}, state}
          {_preloaded_or_missing, state} -> {:data, state}
        end
    end
  end

  defp mark({:call, anno, {:remote, _, {:atom, _, module}, {:atom, _, name}}, args}, context) do
    arity = length(args)

    cond do
      module == :erlang and {name, arity} in @mfa_functions ->
        throw({:harmony, "calls :erlang.#{name}/#{arity}, which takes a module as data"})

      module == :erlang and name == :nif_error ->
        throw({:harmony, "is implemented natively"})

      primitive?(module, name, arity, context) ->
        {:call, anno, {:harmony_primitive, module, name}, mark(args, context)}

      true ->
        {:call, anno, {:harmony_ref, {module, name, arity}}, mark(args, context)}
    end
  end

  defp mark({:call, _, {:remote, _, _, _}, _}, _context),
    do: throw({:harmony, "calls a function on a module chosen at runtime"})

  # Erlang writes calls to auto-imported BIFs (`is_integer(X)`) and imported
  # functions as local calls.
  defp mark({:call, anno, {:atom, _, name}, args}, context) do
    arity = length(args)

    cond do
      Map.has_key?(context.code.functions, {name, arity}) ->
        {:call, anno, {:harmony_ref, {context.module, name, arity}}, mark(args, context)}

      module = context.code.imports[{name, arity}] ->
        mark(
          {:call, anno, {:remote, anno, {:atom, anno, module}, {:atom, anno, name}}, args},
          context
        )

      :erl_internal.bif(name, arity) ->
        mark(
          {:call, anno, {:remote, anno, {:atom, anno, :erlang}, {:atom, anno, name}}, args},
          context
        )

      true ->
        throw({:harmony, "calls #{name}/#{arity}, which isn't defined"})
    end
  end

  defp mark({:fun, anno, {:function, name, arity}}, context) when is_atom(name),
    do: {:harmony_fun, anno, {context.module, name, arity}}

  defp mark(
         {:fun, anno, {:function, {:atom, _, module}, {:atom, _, name}, {:integer, _, arity}}},
         context
       ) do
    if primitive?(module, name, arity, context),
      do: {:harmony_primitive_fun, anno, module, name, arity},
      else: {:harmony_fun, anno, {module, name, arity}}
  end

  defp mark({:fun, _, {:function, _, _, _}}, _context),
    do: throw({:harmony, "captures a function on a module chosen at runtime"})

  defp mark(tuple, context) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&mark(&1, context)) |> List.to_tuple()

  defp mark(list, context) when is_list(list), do: Enum.map(list, &mark(&1, context))
  defp mark(other, _context), do: other

  # Built-in functions, from :erlang or any other module, and modules preloaded
  # into the VM are part of the VM rather than code to hash.
  defp primitive?(module, name, arity, context) do
    not Map.has_key?(context.user, module) and
      (module == :erlang or :erlang.is_builtin(module, name, arity) or
         Map.get(context.available, module) == :preloaded)
  end

  defp calls(term), do: term |> collect([]) |> Enum.uniq() |> Enum.sort()

  defp collect({:harmony_ref, mfa}, acc), do: [mfa | acc]
  defp collect({:harmony_fun, _, mfa}, acc), do: [mfa | acc]
  defp collect(tuple, acc) when is_tuple(tuple), do: collect(Tuple.to_list(tuple), acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_other, acc), do: acc

  # Atoms left in a marked shape are data: calls have been replaced by markers.
  defp atoms(term), do: term |> collect_atoms([]) |> Enum.uniq()

  defp collect_atoms({:atom, _, atom}, acc), do: [atom | acc]

  defp collect_atoms(tuple, acc) when is_tuple(tuple),
    do: collect_atoms(Tuple.to_list(tuple), acc)

  defp collect_atoms(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_atoms/2)
  defp collect_atoms(_other, acc), do: acc

  ## Deciding which library functions are hashed and which are pinned

  # A library function Harmony can't hash is pinned: called by name. That only
  # works if it's exported, so a private one is blocked, and its callers must be
  # pinned in turn. Repeats until nothing changes.
  defp resolve(roots, state) do
    known =
      Map.merge(
        Map.new(state.analysed, fn {mfa, _} -> {mfa, :hashed} end),
        Map.new(state.unhashable, fn {mfa, reason} -> {mfa, pin(mfa, reason, state)} end)
      )

    # Calls to functions of your modules that don't exist.
    initial =
      for {_mfa, info} <- state.analysed,
          callee <- info.calls,
          not Map.has_key?(known, callee),
          into: known,
          do: {callee, {:blocked, :missing}}

    status = settle(initial, state)

    Enum.find_value(roots, {:ok, status}, fn mfa ->
      Enum.find_value(state.analysed[mfa].calls, fn callee ->
        case status[callee] do
          {:blocked, :missing} ->
            {:error, "#{display(mfa)} calls #{display(callee)}, which isn't defined"}

          {:blocked, reason} ->
            {:error, "#{display(mfa)} calls #{display(callee)}, which #{reason}"}

          _ ->
            nil
        end
      end)
    end)
  end

  defp settle(status, state) do
    changed =
      for {mfa, :hashed} <- status,
          not Map.has_key?(state.user, elem(mfa, 0)),
          blocked <- [Enum.find(state.analysed[mfa].calls, &match?({:blocked, _}, status[&1]))],
          blocked != nil,
          into: %{},
          do: {mfa, pin(mfa, "calls #{display(blocked)}, which can't be called by name", state)}

    if changed == %{}, do: status, else: settle(Map.merge(status, changed), state)
  end

  defp pin(_mfa, :missing, _state), do: {:blocked, :missing}

  defp pin({module, name, arity}, reason, state) do
    case Map.fetch!(state.libraries, module) do
      {:ok, code, md5} ->
        if MapSet.member?(code.exports, {name, arity}),
          do: {:pinned, md5, reason},
          else: {:blocked, "can't be hashed (it #{reason}) and isn't exported"}

      {:unhashable, md5, _} ->
        {:pinned, md5, reason}
    end
  end

  ## Hashing, callees first, and compiling

  defp objects(roots, status, state) do
    hashed = reachable(roots, status, state)
    analysed = Map.take(state.analysed, hashed)

    hashes =
      analysed
      |> components(status)
      |> Enum.reduce(%{}, &hash_component(&1, analysed, status, &2))

    objects =
      Map.new(analysed, fn {mfa, info} ->
        hash = hashes[mfa]
        callees = Enum.filter(info.calls, &(status[&1] == :hashed))

        object = %Object{
          hash: hash,
          arity: info.arity,
          dependencies: callees |> Enum.map(&hashes[&1]) |> Enum.uniq() |> Enum.sort(),
          requires: requires(info, status),
          beam:
            Object.compile(
              hash,
              info.arity,
              substitute(info.shape, &compile_ref(&1, status, hashes))
            )
        }

        {hash, object}
      end)

    {user, library} =
      Enum.split_with(hashes, fn {{module, _, _}, _} -> Map.has_key?(state.user, module) end)

    used = pinned_callees(analysed, status)

    pinned =
      for {mfa, {:pinned, _md5, reason}} <- status,
          MapSet.member?(used, mfa),
          into: %{},
          do: {display(mfa), reason}

    %__MODULE__{
      names: Map.new(user, fn {mfa, hash} -> {display(mfa), hash} end),
      library: Map.new(library, fn {mfa, hash} -> {display(mfa), hash} end),
      pinned: pinned,
      objects: objects
    }
  end

  defp reachable(roots, status, state), do: walk(roots, status, state, MapSet.new())

  defp walk([], _status, _state, seen), do: MapSet.to_list(seen)

  defp walk([mfa | rest], status, state, seen) do
    if MapSet.member?(seen, mfa) or status[mfa] != :hashed,
      do: walk(rest, status, state, seen),
      else: walk(state.analysed[mfa].calls ++ rest, status, state, MapSet.put(seen, mfa))
  end

  defp pinned_callees(analysed, status) do
    for {_mfa, info} <- analysed,
        callee <- info.calls,
        match?({:pinned, _, _}, status[callee]),
        into: MapSet.new(),
        do: callee
  end

  # Modules whose exact build this function depends on, by MD5.
  defp requires(info, status) do
    for callee <- info.calls,
        {:pinned, md5, _} <- [status[callee]],
        into: info.named,
        do: {elem(callee, 0), md5}
  end

  defp components(analysed, status) do
    graph = :digraph.new()

    try do
      for mfa <- Map.keys(analysed), do: :digraph.add_vertex(graph, mfa)

      for {mfa, info} <- analysed,
          callee <- info.calls,
          status[callee] == :hashed,
          do: :digraph.add_edge(graph, mfa, callee)

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

  defp hash_component(members, analysed, status, hashes) do
    in_group = MapSet.new(members)

    outside = fn mfa ->
      case status[mfa] do
        :hashed -> {:hash, hashes[mfa]}
        {:pinned, _md5, _} -> {:pinned, mfa}
      end
    end

    # Order members by their shape with calls inside the group blanked out.
    # Names only break ties between members that look exactly alike.
    ordered =
      members
      |> Enum.map(fn mfa ->
        blank =
          shape(
            mfa,
            analysed,
            status,
            &if(MapSet.member?(in_group, &1), do: :recursive, else: outside.(&1))
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
          status,
          &if(Map.has_key?(position, &1), do: {:self, position[&1]}, else: outside.(&1))
        )
      end)

    Enum.reduce(ordered, hashes, fn mfa, hashes ->
      Map.put(hashes, mfa, digest({:harmony_function_v2, group, position[mfa]}))
    end)
  end

  # What a hash covers: arity, normalized code, and the modules it pins.
  defp shape(mfa, analysed, status, reference) do
    info = Map.fetch!(analysed, mfa)
    requires = info |> requires(status) |> Enum.sort()
    {info.arity, substitute(info.shape, &shape_ref(&1, reference)), requires}
  end

  defp shape_ref({:call, mfa}, reference), do: {:ref, reference.(mfa)}
  defp shape_ref({:fun, _anno, mfa}, reference), do: {:fun_ref, reference.(mfa)}
  defp shape_ref({:primitive, module, name}, _reference), do: {:primitive, module, name}

  defp shape_ref({:primitive_fun, _anno, module, name, arity}, _),
    do: {:primitive_fun, module, name, arity}

  defp compile_ref({:call, {module, name, _} = mfa}, status, hashes) do
    case status[mfa] do
      :hashed -> {:remote, 0, {:atom, 0, Object.module(hashes[mfa])}, {:atom, 0, :run}}
      {:pinned, _, _} -> {:remote, 0, {:atom, 0, module}, {:atom, 0, name}}
    end
  end

  defp compile_ref({:fun, anno, {module, name, arity} = mfa}, status, hashes) do
    {module, name} =
      case status[mfa] do
        :hashed -> {Object.module(hashes[mfa]), :run}
        {:pinned, _, _} -> {module, name}
      end

    {:fun, anno, {:function, {:atom, anno, module}, {:atom, anno, name}, {:integer, anno, arity}}}
  end

  defp compile_ref({:primitive, module, name}, _status, _hashes),
    do: {:remote, 0, {:atom, 0, module}, {:atom, 0, name}}

  defp compile_ref({:primitive_fun, anno, module, name, arity}, _status, _hashes),
    do:
      {:fun, anno,
       {:function, {:atom, anno, module}, {:atom, anno, name}, {:integer, anno, arity}}}

  defp substitute({:harmony_ref, mfa}, replace), do: replace.({:call, mfa})
  defp substitute({:harmony_fun, anno, mfa}, replace), do: replace.({:fun, anno, mfa})

  defp substitute({:harmony_primitive, module, name}, replace),
    do: replace.({:primitive, module, name})

  defp substitute({:harmony_primitive_fun, anno, module, name, arity}, replace),
    do: replace.({:primitive_fun, anno, module, name, arity})

  defp substitute(tuple, replace) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&substitute(&1, replace)) |> List.to_tuple()

  defp substitute(list, replace) when is_list(list), do: Enum.map(list, &substitute(&1, replace))
  defp substitute(other, _replace), do: other

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

  defp digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic, minor_version: 2]))
    |> Base.encode16(case: :lower)
  end
end
