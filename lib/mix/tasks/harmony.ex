defmodule Mix.Tasks.Harmony.Hash do
  use Mix.Task
  @shortdoc "Print each function's content hash"
  @moduledoc """
  Usage: `mix harmony.hash [PATH...] [--library] [--pinned]`

  PATH is a `.beam` file, a directory of them (such as `ebin`), or an `.ex` or
  `.erl` source. With no PATH, compiles the current Mix project and reads it.

  `--library` also prints the library functions hashed along with your code,
  and `--pinned` the library functions called by name, with the reason.
  """

  @impl true
  def run(args) do
    {options, paths} = OptionParser.parse!(args, strict: [library: :boolean, pinned: :boolean])
    codebase = Harmony.CLI.codebase!(paths)
    shell = Mix.shell()

    for {name, hash} <- Enum.sort(codebase.names) do
      shell.info("#{Harmony.CLI.short(hash)}  #{name}")
    end

    if codebase.library != %{} or codebase.pinned != %{} do
      shell.info(
        "\n#{map_size(codebase.library)} library functions hashed, " <>
          "#{map_size(codebase.pinned)} pinned (called by name)"
      )
    end

    if options[:library] do
      for {name, hash} <- Enum.sort(codebase.library),
          do: shell.info("#{Harmony.CLI.short(hash)}  #{name}")
    end

    if options[:pinned] do
      for {name, reason} <- Enum.sort(codebase.pinned),
          do: shell.info("pinned  #{name}: #{reason}")
    end
  end
end

defmodule Mix.Tasks.Harmony.Deploy do
  use Mix.Task
  @shortdoc "Store new function objects and make a new release current"
  @moduledoc """
  Usage: `mix harmony.deploy [PATH...] [--store DIR]`

  PATH is a `.beam` file, a directory of them (such as `ebin`), or an `.ex` or
  `.erl` source. With no PATH, compiles the current Mix project and reads it.
  """

  @impl true
  def run(args) do
    {store, paths} = Harmony.CLI.store!(args, "mix harmony.deploy [PATH...] [--store DIR]")
    codebase = Harmony.CLI.codebase!(paths)

    case Harmony.Store.deploy(store, codebase) do
      {:ok, report} -> print(report)
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp print(report) do
    shell = Mix.shell()
    from = if report.previous, do: " (was #{report.previous})", else: ""
    shell.info("Release #{report.release}#{from}")

    from_libraries =
      if report.new_library_objects > 0,
        do: " (#{report.new_library_objects} from libraries)",
        else: ""

    shell.info(
      "  objects: #{length(report.new_objects)} new#{from_libraries}, " <>
        "#{length(report.reused_objects)} reused, #{report.bytes_written} bytes written"
    )

    if report.pinned > 0 do
      shell.info(
        "  pinned: #{report.pinned} library functions called by name " <>
          "(mix harmony.hash --pinned lists them)"
      )
    end

    %{added: added, removed: removed, changed: changed, renamed: renamed} = report.changes
    for name <- added, do: shell.info("  + #{name}")
    for name <- changed, do: shell.info("  ~ #{name}")
    for {from, to} <- renamed, do: shell.info("  > #{from} -> #{to} (same code)")
    for name <- removed, do: shell.info("  - #{name}")
  end
end

defmodule Mix.Tasks.Harmony.Run do
  use Mix.Task
  @shortdoc "Call a function from the current (or a given) release"
  @moduledoc """
  Usage: `mix harmony.run NAME [INPUT] [--store DIR] [--release N] [--libbeam]`

  NAME is a function such as `Greeter.main` or `:text.shout`; it is called
  with one argument, INPUT, as a binary (default `""`).

  `--libbeam` runs the call in a fresh libbeam Isolate; it needs the project
  built with `HARMONY_LIBBEAM=1` and a native host.
  """

  @impl true
  def run(args) do
    {options, positional, []} =
      OptionParser.parse(args, strict: [store: :string, release: :integer, libbeam: :boolean])

    {name, input} =
      case positional do
        [name] ->
          {name, ""}

        [name, input] ->
          {name, input}

        _ ->
          Mix.raise("Usage: mix harmony.run NAME [INPUT] [--store DIR] [--release N] [--libbeam]")
      end

    store = Keyword.get(options, :store, ".harmony")
    release = Keyword.get(options, :release, :head)
    name = if String.contains?(name, "/"), do: name, else: name <> "/1"

    result =
      if options[:libbeam] do
        runtime = Module.concat(Harmony.Runtime, Libbeam)

        unless Code.ensure_loaded?(runtime),
          do: Mix.raise("libbeam support is off; rebuild with HARMONY_LIBBEAM=1 (see README)")

        runtime.run(store, name, input, release)
      else
        Harmony.Runtime.run(store, name, [input], release)
      end

    case result do
      {:ok, output} when is_binary(output) -> Mix.shell().info(output)
      {:ok, output} -> Mix.shell().info(inspect(output))
      {:error, reason} -> Mix.raise(reason)
    end
  end
end

defmodule Mix.Tasks.Harmony.Log do
  use Mix.Task
  @shortdoc "List releases and their names"
  @moduledoc "Usage: `mix harmony.log [--store DIR]`"

  @impl true
  def run(args) do
    {store, []} = Harmony.CLI.store!(args, "mix harmony.log [--store DIR]")
    {:ok, head} = Harmony.Store.head(store)

    for number <- Enum.reverse(Harmony.Store.releases(store)) do
      {:ok, release} = Harmony.Store.release(store, number)
      marker = if number == head, do: "* ", else: "  "

      names =
        release.names
        |> Enum.sort()
        |> Enum.map_join(" ", fn {n, h} -> "#{n}@#{Harmony.CLI.short(h)}" end)

      Mix.shell().info("#{marker}#{number}  #{names}")
    end
  end
end

defmodule Mix.Tasks.Harmony.Rollback do
  use Mix.Task
  @shortdoc "Make an earlier release current"
  @moduledoc "Usage: `mix harmony.rollback N [--store DIR]`"

  @impl true
  def run(args) do
    {store, [number]} = Harmony.CLI.store!(args, "mix harmony.rollback N [--store DIR]")

    with {n, ""} <- Integer.parse(number),
         :ok <- Harmony.Store.rollback(store, n) do
      Mix.shell().info("Release #{n} is current")
    else
      {:error, reason} -> Mix.raise(reason)
      _ -> Mix.raise("Usage: mix harmony.rollback N [--store DIR]")
    end
  end
end

defmodule Harmony.CLI do
  @moduledoc false

  def store!(args, usage) do
    case OptionParser.parse(args, strict: [store: :string]) do
      {options, positional, []} -> {Keyword.get(options, :store, ".harmony"), positional}
      _ -> Mix.raise("Usage: #{usage}")
    end
  end

  def codebase!([]) do
    Mix.Task.run("compile")
    codebase!([Mix.Project.compile_path()])
  end

  def codebase!(paths) do
    case Harmony.Codebase.from_paths(paths) do
      {:ok, codebase} -> codebase
      {:error, reason} -> Mix.raise(reason)
    end
  end

  def short(hash), do: binary_part(hash, 0, 10)
end
