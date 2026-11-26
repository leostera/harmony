defmodule Mix.Tasks.Harmony.Hash do
  use Mix.Task
  @shortdoc "Print each function's content hash"
  @moduledoc "Usage: `mix harmony.hash FILE`"

  @impl true
  def run([file]) do
    codebase = Harmony.CLI.codebase!(file)

    for {name, hash} <- Enum.sort(codebase.names) do
      Mix.shell().info("#{Harmony.CLI.short(hash)}  #{name}")
    end
  end

  def run(_), do: Mix.raise("Usage: mix harmony.hash FILE")
end

defmodule Mix.Tasks.Harmony.Deploy do
  use Mix.Task
  @shortdoc "Store new function objects and make a new release current"
  @moduledoc "Usage: `mix harmony.deploy FILE [--store DIR]`"

  @impl true
  def run(args) do
    {store, [file]} = Harmony.CLI.store!(args, "mix harmony.deploy FILE [--store DIR]")
    codebase = Harmony.CLI.codebase!(file)

    case Harmony.Store.deploy(store, codebase) do
      {:ok, report} -> print(report)
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp print(report) do
    shell = Mix.shell()
    from = if report.previous, do: " (was #{report.previous})", else: ""
    shell.info("Release #{report.release}#{from}")

    shell.info(
      "  objects: #{length(report.new_objects)} new, #{length(report.reused_objects)} reused, " <>
        "#{report.bytes_written} bytes written"
    )

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

    result =
      if options[:libbeam] do
        runtime = Module.concat(Harmony.Runtime, Libbeam)

        unless Code.ensure_loaded?(runtime),
          do: Mix.raise("libbeam support is off; rebuild with HARMONY_LIBBEAM=1 (see README)")

        runtime.run(store, name, input, release)
      else
        Harmony.Runtime.run(store, name, input, release)
      end

    case result do
      {:ok, output} -> Mix.shell().info(output)
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

  def codebase!(file) do
    with {:ok, source} <- File.read(file),
         {:ok, codebase} <- Harmony.Codebase.from_source(source) do
      codebase
    else
      {:error, reason} when is_atom(reason) -> Mix.raise("#{file}: #{:file.format_error(reason)}")
      {:error, reason} -> Mix.raise("#{file}: #{reason}")
    end
  end

  def short(hash), do: binary_part(hash, 0, 10)
end
