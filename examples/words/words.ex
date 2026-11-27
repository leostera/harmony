defmodule Words do
  # Calls Elixir's standard library, which Harmony hashes along with this code.
  def main(text), do: text |> String.split() |> Enum.map(&String.capitalize/1) |> Enum.join(" ")
end
