defmodule HarmonyLibrariesTest do
  # Tests compile modules with the same names, so they run one at a time.
  use ExUnit.Case, async: false

  alias Harmony.{Codebase, Object, Runtime, Store}

  defp tmp(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp codebase!(files) do
    dir = tmp("harmony-src")
    for {name, source} <- files, do: File.write!(Path.join(dir, name), source)
    {:ok, codebase} = Codebase.from_paths([dir])
    codebase
  end

  # Elixir's standard library closure is large, so it's built once.
  setup_all do
    {:ok, words} = Codebase.from_paths(["examples/words"])
    %{words: words}
  end

  test "library functions are hashed with your code, callees first" do
    {:ok, codebase} = Codebase.from_paths(["examples/mixed"])

    assert Map.keys(codebase.library) ==
             [":lists.seq/2", ":lists.seq_loop/3", ":lists.sum/1", ":lists.sum/2"]

    assert codebase.pinned == %{}
    sum_to = codebase.objects[codebase.names[":text.sum_to/1"]]
    assert codebase.library[":lists.sum/1"] in sum_to.dependencies
    assert sum_to.requires == %{}

    store = tmp("harmony-store")
    {:ok, _} = Store.deploy(store, codebase)
    assert {:ok, "1 + ... + 10 = 55"} = Runtime.run(store, "Shouter.total/1", ["10"])
  end

  test "Elixir's standard library runs as hashed objects", %{words: words} do
    assert Map.has_key?(words.library, "Enum.map/2")
    assert Map.has_key?(words.library, "String.capitalize/1")

    store = tmp("harmony-store")
    {:ok, _} = Store.deploy(store, words)
    assert {:ok, "Hello Big World"} = Runtime.run(store, "Words.main/1", ["hello big world"])
    assert {:module, _} = :code.ensure_loaded(Object.module(words.library["Enum.map/2"]))
  end

  test "functions Harmony can't hash are pinned to their module's build", %{words: words} do
    assert words.pinned != %{}
    assert Enum.all?(words.pinned, fn {_name, reason} -> is_binary(reason) end)

    store = tmp("harmony-store")
    {:ok, _} = Store.deploy(store, words)

    # As if the release had been built on a VM with a different Elixir.
    path = Path.join(store, "releases/1.json")
    release = path |> File.read!() |> :json.decode()
    [{hash, modules} | _] = Enum.sort(release["requires"])
    [{module, _md5} | _] = Enum.sort(modules)
    release = put_in(release, ["requires", hash, module], String.duplicate("0", 32))
    File.write!(path, :json.encode(release))

    assert {:error, message} = Runtime.run(store, "Words.main/1", ["hi"])
    assert message =~ "deploy again from this VM"
  end

  test "library modules can be data, and interpolation works" do
    codebase =
      codebase!([
        {"m.ex",
         ~S"""
         defmodule M do
           def module(_), do: Enum
           def say(x), do: "got #{x}"
         end
         """}
      ])

    md5 = Base.encode16(Enum.module_info(:md5), case: :lower)
    assert codebase.objects[codebase.names["M.module/1"]].requires == %{Enum => md5}

    store = tmp("harmony-store")
    {:ok, _} = Store.deploy(store, codebase)
    assert {:ok, Enum} = Runtime.run(store, "M.module/1", [nil])
    assert {:ok, "got 42"} = Runtime.run(store, "M.say/1", [42])
  end
end
