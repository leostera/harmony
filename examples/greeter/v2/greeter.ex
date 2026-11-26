defmodule Greeter do
  def main(name), do: greeting(name)

  # v2: a new greeting. punctuation/0 and health/1 are untouched.
  def greeting(name), do: "Howdy, " <> name <> punctuation()

  defp punctuation, do: "!"

  def health(_input), do: "ok"
end
