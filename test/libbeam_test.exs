defmodule Harmony.LibbeamTest do
  use ExUnit.Case, async: false

  @moduletag :libbeam

  test "runs any release in a fresh libbeam Isolate" do
    store = Path.join(System.tmp_dir!(), "harmony-libbeam-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(store) end)
    runtime = Module.concat(Harmony.Runtime, Libbeam)

    for version <- [:v1, :v2] do
      {:ok, codebase} = Harmony.Codebase.from_source(File.read!("examples/greeter/#{version}.hm"))
      {:ok, _} = Harmony.Store.deploy(store, codebase)
    end

    assert {:ok, "Howdy, Joe!"} = runtime.run(store, "main", "Joe")
    assert {:ok, "Hello, Joe!"} = runtime.run(store, "main", "Joe", 1)
  end
end
