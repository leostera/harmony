defmodule Greeter do
  def main(name), do: greeting(name)

  def greeting(name), do: "Hello, " <> name <> punctuation()

  defp punctuation, do: "!"

  def health(_input), do: "ok"
end
