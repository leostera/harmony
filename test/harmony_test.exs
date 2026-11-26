defmodule HarmonyTest do
  use ExUnit.Case, async: true

  alias Harmony.{Codebase, Runtime, Store, Syntax}

  defp codebase!(source) do
    {:ok, codebase} = Codebase.from_source(source)
    codebase
  end

  defp example(version), do: File.read!("examples/greeter/#{version}.hm")

  defp store do
    path = Path.join(System.tmp_dir!(), "harmony-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "syntax" do
    test "parses literals, input, calls and concatenation" do
      assert {:ok,
              %{
                "f" => {:concat, [{:literal, "a\n"}, :input, {:call, "g", :input}]},
                "g" => :input
              }} =
               Syntax.parse(
                 ~s{-- comment\nf = "a\\n" ++ input ++ g(input)\ng = input -- trailing\n}
               )
    end

    test "rejects malformed definitions with a line number" do
      assert {:error, "line 1: " <> _} = Syntax.parse("f = ")
      assert {:error, "line 2: f is defined twice"} = Syntax.parse("f = input\nf = input")
      assert {:error, "line 1: g must be called" <> _} = Syntax.parse("f = g")
      assert {:error, "line 1: unterminated string"} = Syntax.parse(~s(f = "oops))
    end
  end

  describe "content addressing" do
    test "hashes are deterministic, including the compiled bytes" do
      assert codebase!(example(:v1)) == codebase!(example(:v1))
    end

    test "names don't affect hashes: identical definitions share one object" do
      codebase = codebase!(~s(a = "same"\nb = "same"))
      assert codebase.names["a"] == codebase.names["b"]
      assert map_size(codebase.objects) == 1
    end

    test "a change rehashes the function and its callers, nothing else" do
      v1 = codebase!(example(:v1))
      v2 = codebase!(example(:v2))

      for name <- ["greeting", "main"], do: assert(v1.names[name] != v2.names[name])
      for name <- ["punctuation", "health"], do: assert(v1.names[name] == v2.names[name])
    end

    test "renaming a function changes no hashes, not even its callers'" do
      v2 = codebase!(example(:v2))
      v3 = codebase!(example(:v3))

      assert v3.names["salute"] == v2.names["greeting"]
      assert v3.names["main"] == v2.names["main"]
      assert Map.keys(v3.objects) == Map.keys(v2.objects)
    end

    test "rejects recursion and undefined calls" do
      assert {:error, "recursion is not supported yet: a -> b -> a"} =
               Codebase.from_source("a = b(input)\nb = a(input)")

      assert {:error, "a calls nope, which is not defined"} =
               Codebase.from_source("a = nope(input)")
    end
  end

  describe "differential deploys" do
    test "each release ships only objects the store lacks" do
      store = store()

      assert {:ok, %{release: 1, new_objects: first}} =
               Store.deploy(store, codebase!(example(:v1)))

      assert length(first) == 4

      assert {:ok, report} = Store.deploy(store, codebase!(example(:v2)))
      assert %{release: 2, previous: 1} = report
      assert length(report.new_objects) == 2
      assert length(report.reused_objects) == 2
      assert report.changes.changed == ["greeting", "main"]

      assert {:ok, report} = Store.deploy(store, codebase!(example(:v3)))
      assert report.new_objects == []
      assert report.bytes_written == 0
      assert report.changes.renamed == [{"greeting", "salute"}]
    end

    test "runs any release; rollback moves HEAD" do
      store = store()
      {:ok, _} = Store.deploy(store, codebase!(example(:v1)))
      {:ok, _} = Store.deploy(store, codebase!(example(:v2)))

      assert {:ok, "Howdy, Joe!"} = Runtime.run(store, "main", "Joe")
      assert {:ok, "Hello, Joe!"} = Runtime.run(store, "main", "Joe", 1)

      assert :ok = Store.rollback(store, 1)
      assert {:ok, "Hello, Joe!"} = Runtime.run(store, "main", "Joe")
      assert {:error, "release 9 does not exist"} = Store.rollback(store, 9)
    end

    test "old and new versions are live in the same VM at once" do
      store = store()
      {:ok, _} = Store.deploy(store, codebase!(example(:v1)))
      {:ok, _} = Store.deploy(store, codebase!(example(:v2)))

      {:ok, old} = Store.release(store, 1)
      {:ok, new} = Store.release(store, 2)
      {:ok, _} = Runtime.run(store, "main", "", 1)
      {:ok, _} = Runtime.run(store, "main", "", 2)

      assert {:ok, "Hello, Ann!"} = Runtime.call(old.names["main"], "Ann")
      assert {:ok, "Howdy, Ann!"} = Runtime.call(new.names["main"], "Ann")
    end

    test "refuses objects whose bytes don't match their hash" do
      store = store()
      {:ok, _} = Store.deploy(store, codebase!(~s(main = "x")))
      [object] = Path.wildcard(Path.join(store, "objects/*.beam"))
      File.write!(object, "not a beam")

      assert {:error, "object " <> _} = Runtime.run(store, "main", "")
      assert {:error, _} = Store.deploy(store, codebase!(~s(main = "x")))
    end
  end
end
