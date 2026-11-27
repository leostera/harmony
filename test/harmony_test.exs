defmodule HarmonyTest do
  # Tests compile modules with the same names, so they run one at a time.
  use ExUnit.Case, async: false

  alias Harmony.{Codebase, Runtime, Store}

  defp tmp(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # Writes {file name, source} pairs to a fresh directory and builds them.
  defp codebase(files) do
    dir = tmp("harmony-src")
    for {name, source} <- files, do: File.write!(Path.join(dir, name), source)
    Codebase.from_paths([dir])
  end

  defp codebase!(files) do
    {:ok, codebase} = codebase(files)
    codebase
  end

  defp greeter!(version) do
    {:ok, codebase} = Codebase.from_paths(["examples/greeter/#{version}"])
    codebase
  end

  describe "reading BEAM files" do
    test "compiled .beam files and their sources give the same codebase" do
      ebin = tmp("harmony-ebin")

      # As `mix compile` does in dev; `mix test` turns debug info off.
      Code.put_compiler_option(:debug_info, true)

      {:ok, _, _} =
        Kernel.ParallelCompiler.compile_to_path(["examples/greeter/v1/greeter.ex"], ebin,
          return_diagnostics: true
        )

      Code.put_compiler_option(:debug_info, false)

      {:ok, :text, beam} = :compile.file(~c"examples/mixed/text.erl", [:binary, :debug_info])
      File.write!(Path.join(ebin, "text.beam"), beam)
      for module <- [Greeter, :text], do: :code.purge(module) && :code.delete(module)

      {:ok, from_beams} = Codebase.from_paths([ebin])

      {:ok, from_sources} =
        Codebase.from_paths(["examples/greeter/v1", "examples/mixed/text.erl"])

      assert from_beams == from_sources
    end

    test "Elixir can call Erlang, and calls resolve by hash across languages" do
      {:ok, codebase} = Codebase.from_paths(["examples/mixed"])
      [shout] = Map.fetch!(codebase.objects, codebase.names["Shouter.main/1"]).dependencies
      assert shout == codebase.names[":text.shout/1"]
    end

    test "refuses BEAM files without debug info" do
      dir = tmp("harmony-nodebug")
      File.write!(Path.join(dir, "plain.erl"), "-module(plain).\n-export([f/1]).\nf(X) -> X.\n")

      {:ok, :plain, beam} =
        :compile.file(String.to_charlist(Path.join(dir, "plain.erl")), [:binary])

      File.write!(Path.join(dir, "plain.beam"), beam)
      File.rm!(Path.join(dir, "plain.erl"))

      assert {:error, message} = Codebase.from_paths([dir])
      assert message =~ "compiled without debug_info"
    end
  end

  describe "content addressing" do
    test "is deterministic, down to the compiled bytes" do
      assert greeter!(:v1) == greeter!(:v1)
    end

    test "a change rehashes the function and its callers, nothing else" do
      v1 = greeter!(:v1)
      v2 = greeter!(:v2)

      for name <- ["Greeter.greeting/1", "Greeter.main/1"],
          do: assert(v1.names[name] != v2.names[name])

      for name <- ["Greeter.punctuation/0", "Greeter.health/1"],
          do: assert(v1.names[name] == v2.names[name])
    end

    test "renaming a function or a variable changes no hashes" do
      v2 = greeter!(:v2)
      v3 = greeter!(:v3)

      assert v3.names["Greeter.salute/1"] == v2.names["Greeter.greeting/1"]
      assert v3.names["Greeter.main/1"] == v2.names["Greeter.main/1"]
      assert Map.keys(v3.objects) == Map.keys(v2.objects)
    end

    test "moving a function to another module, or shifting lines, changes no hashes" do
      one =
        codebase!([
          {"a.ex",
           ~S'''
           defmodule A do
             def main(x), do: x <> suffix()
             def suffix, do: "!"
           end
           '''}
        ])

      moved =
        codebase!([
          {"a.ex",
           ~S'''


           # comments and blank lines move everything down
           defmodule A do
             def main(x), do: x <> B.suffix()
           end
           '''},
          {"b.ex",
           ~S'''
           defmodule B do
             def suffix, do: "!"
           end
           '''}
        ])

      assert moved.names["A.main/1"] == one.names["A.main/1"]
      assert moved.names["B.suffix/0"] == one.names["A.suffix/0"]
    end

    test "identical functions are one object" do
      codebase =
        codebase!([
          {"a.ex", "defmodule A do\n  def ok(_), do: \"ok\"\nend\n"},
          {"b.ex", "defmodule B do\n  def fine(_), do: \"ok\"\nend\n"}
        ])

      assert codebase.names["A.ok/1"] == codebase.names["B.fine/1"]
      assert map_size(codebase.objects) == 1
    end

    test "mutually recursive functions are hashed as a group" do
      parity = fn even, odd ->
        [
          {"p.ex",
           """
           defmodule P do
             def check(n), do: if(#{even}(n), do: "even", else: "odd")
             def #{even}(0), do: true
             def #{even}(n), do: #{odd}(n - 1)
             def #{odd}(0), do: false
             def #{odd}(n), do: #{even}(n - 1)
           end
           """}
        ]
      end

      named = codebase!(parity.("even?", "odd?"))
      renamed = codebase!(parity.("is_even", "is_odd"))

      assert renamed.names["P.is_even/1"] == named.names["P.even?/1"]
      assert renamed.names["P.is_odd/1"] == named.names["P.odd?/1"]
      assert named.names["P.even?/1"] != named.names["P.odd?/1"]

      store = tmp("harmony-store")
      {:ok, _} = Store.deploy(store, named)
      assert {:ok, "odd"} = Runtime.run(store, "P.check/1", [7])
      assert {:ok, "even"} = Runtime.run(store, "P.check/1", [10])
    end
  end

  describe "the subset" do
    defp rejection(body) do
      {:error, message} = codebase([{"m.ex", "defmodule M do\n#{body}\nend\n"}])
      message
    end

    test "module names can only be used to call functions" do
      assert rejection("def f(_), do: __MODULE__") =~ "uses the module M as a value"
      assert rejection("defstruct [:a]") =~ "uses the module M as a value"
      assert rejection("def f(x), do: apply(M, :f, [x])") =~ "takes a module as data"
      assert rejection("def f(_), do: {M, :f}") =~ "uses the module M as a value"
      assert rejection("def f(m), do: m.run(1)") =~ "on a module chosen at runtime"
      assert rejection("def f(m), do: :erlang.apply(m, :f, [])") =~ "takes a module as data"
    end

    test "every call must be defined" do
      # Elixir only warns about undefined remote calls; Harmony refuses them.
      for {call, callee} <- [
            {"M.nope(x)", "M.nope/1"},
            {"Enum.nope(x)", "Enum.nope/1"},
            {"NoSuch.f(x)", "NoSuch.f/1"}
          ] do
        {message, _warning} =
          ExUnit.CaptureIO.with_io(:stderr, fn -> rejection("def f(x), do: #{call}") end)

        assert message =~ "M.f/1 calls #{callee}, which isn't defined"
      end
    end
  end

  describe "differential deploys" do
    test "each release ships only objects the store lacks" do
      store = tmp("harmony-store")

      assert {:ok, %{release: 1, new_objects: first}} = Store.deploy(store, greeter!(:v1))
      assert length(first) == 4

      assert {:ok, report} = Store.deploy(store, greeter!(:v2))
      assert %{release: 2, previous: 1} = report
      assert length(report.new_objects) == 2
      assert length(report.reused_objects) == 2
      assert report.changes.changed == ["Greeter.greeting/1", "Greeter.main/1"]

      assert {:ok, report} = Store.deploy(store, greeter!(:v3))
      assert report.new_objects == []
      assert report.bytes_written == 0
      assert report.changes.renamed == [{"Greeter.greeting/1", "Greeter.salute/1"}]
    end

    test "runs any release; rollback moves HEAD" do
      store = tmp("harmony-store")
      {:ok, _} = Store.deploy(store, greeter!(:v1))
      {:ok, _} = Store.deploy(store, greeter!(:v2))

      assert {:ok, "Howdy, Joe!"} = Runtime.run(store, "Greeter.main/1", ["Joe"])
      assert {:ok, "Hello, Joe!"} = Runtime.run(store, "Greeter.main/1", ["Joe"], 1)

      assert :ok = Store.rollback(store, 1)
      assert {:ok, "Hello, Joe!"} = Runtime.run(store, "Greeter.main/1", ["Joe"])
      assert {:error, "release 9 does not exist"} = Store.rollback(store, 9)
    end

    test "old and new versions are live in the same VM at once" do
      store = tmp("harmony-store")
      {:ok, _} = Store.deploy(store, greeter!(:v1))
      {:ok, _} = Store.deploy(store, greeter!(:v2))

      {:ok, old} = Store.release(store, 1)
      {:ok, new} = Store.release(store, 2)
      {:ok, _} = Runtime.run(store, "Greeter.main/1", [""], 1)
      {:ok, _} = Runtime.run(store, "Greeter.main/1", [""], 2)

      assert {:ok, "Hello, Ann!"} = Runtime.call(old.names["Greeter.main/1"], ["Ann"])
      assert {:ok, "Howdy, Ann!"} = Runtime.call(new.names["Greeter.main/1"], ["Ann"])
    end

    test "refuses objects whose bytes don't match their hash" do
      store = tmp("harmony-store")
      {:ok, _} = Store.deploy(store, greeter!(:v1))
      [object | _] = Path.wildcard(Path.join(store, "objects/*.beam"))
      File.write!(object, "not a beam")

      assert {:error, "object " <> _} = Runtime.run(store, "Greeter.main/1", [""])
      assert {:error, _} = Store.deploy(store, greeter!(:v1))
    end
  end
end
