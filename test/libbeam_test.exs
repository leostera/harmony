defmodule Harmony.LibbeamTest do
  use ExUnit.Case, async: false

  @moduletag :libbeam

  test "runs any release in a fresh libbeam Isolate" do
    store = Path.join(System.tmp_dir!(), "harmony-libbeam-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(store) end)
    runtime = Module.concat(Harmony.Runtime, Libbeam)

    for version <- [:v1, :v2] do
      {:ok, codebase} = Harmony.Codebase.from_paths(["examples/greeter/#{version}"])
      {:ok, _} = Harmony.Store.deploy(store, codebase)
    end

    assert {:ok, "Howdy, Joe!"} = runtime.run(store, "Greeter.main/1", "Joe")
    assert {:ok, "Hello, Joe!"} = runtime.run(store, "Greeter.main/1", "Joe", 1)

    {:ok, mixed} = Harmony.Codebase.from_paths(["examples/mixed"])
    {:ok, _} = Harmony.Store.deploy(store, mixed)
    assert {:ok, "HEY JOE!"} = runtime.run(store, "Shouter.main/1", "joe")

    # Library calls Harmony hashed run in the Isolate; pinned ones can't.
    assert {:ok, "1 + ... + 10 = 55"} = runtime.run(store, "Shouter.total/1", "10")
    {:ok, words} = Harmony.Codebase.from_paths(["examples/words"])
    {:ok, _} = Harmony.Store.deploy(store, words)
    assert {:error, message} = runtime.run(store, "Words.main/1", "hi")
    assert message =~ "which a libbeam Isolate doesn't have"
  end
end
