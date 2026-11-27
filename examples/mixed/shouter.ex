defmodule Shouter do
  # Calls an Erlang module. Across languages, calls still resolve by hash.
  def main(name), do: :text.shout("hey " <> name)

  def total(n),
    do: "1 + ... + " <> n <> " = " <> Integer.to_string(:text.sum_to(String.to_integer(n)))
end
