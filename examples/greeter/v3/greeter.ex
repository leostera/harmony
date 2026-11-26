defmodule Greeter do
  # v3: greeting/1 is now salute/1, and the variable is `who`.
  # No hash changes, so this deploy writes no code.
  def main(who), do: salute(who)

  def salute(who), do: "Howdy, " <> who <> punctuation()

  defp punctuation, do: "!"

  def health(_input), do: "ok"
end
