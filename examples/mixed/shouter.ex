defmodule Shouter do
  # Calls an Erlang module. Across languages, calls still resolve by hash.
  def main(name), do: :text.shout("hey " <> name)
end
