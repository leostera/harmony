defmodule Harmony.Syntax do
  @moduledoc """
  Parses Harmony source into named definitions.

  Every function takes one binary, available as `input`, and returns a binary.

      -- a comment
      greeting = "Hello, " ++ input ++ "!"
      main = greeting(input)

  Expressions are string literals, `input`, calls `name(expr)`, and
  concatenation with `++`. One definition per line.
  """

  @type expr ::
          :input
          | {:literal, binary()}
          | {:call, String.t(), expr()}
          | {:concat, [expr(), ...]}

  @type definitions :: %{String.t() => expr()}

  @spec parse(String.t()) :: {:ok, definitions()} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> blank_or_comment?(line) end)
    |> Enum.reduce_while({:ok, %{}}, fn {line, number}, {:ok, definitions} ->
      case parse_definition(line) do
        {:ok, name, _expr} when is_map_key(definitions, name) ->
          {:halt, {:error, "line #{number}: #{name} is defined twice"}}

        {:ok, name, expr} ->
          {:cont, {:ok, Map.put(definitions, name, expr)}}

        {:error, reason} ->
          {:halt, {:error, "line #{number}: #{reason}"}}
      end
    end)
  end

  defp blank_or_comment?(line) do
    trimmed = String.trim(line)
    trimmed == "" or String.starts_with?(trimmed, "--")
  end

  defp parse_definition(line) do
    with {:ok, tokens} <- tokenize(line, []),
         [{:name, name}, :equals | body] <- tokens,
         {:ok, expr, []} <- parse_expr(body) do
      {:ok, name, expr}
    else
      {:ok, _expr, [token | _]} -> {:error, "unexpected #{describe(token)}"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "expected `name = expression`"}
    end
  end

  defp parse_expr(tokens) do
    with {:ok, first, rest} <- parse_term(tokens) do
      parse_concat(rest, [first])
    end
  end

  defp parse_concat([:concat | tokens], terms) do
    with {:ok, term, rest} <- parse_term(tokens), do: parse_concat(rest, [term | terms])
  end

  defp parse_concat(rest, [single]), do: {:ok, single, rest}
  defp parse_concat(rest, terms), do: {:ok, {:concat, Enum.reverse(terms)}, rest}

  defp parse_term([{:string, bytes} | rest]), do: {:ok, {:literal, bytes}, rest}
  defp parse_term([{:name, "input"} | rest]), do: {:ok, :input, rest}

  defp parse_term([{:name, name}, :open | rest]) do
    case parse_expr(rest) do
      {:ok, argument, [:close | rest]} -> {:ok, {:call, name, argument}, rest}
      {:ok, _argument, _} -> {:error, "expected `)` after the argument to #{name}"}
      error -> error
    end
  end

  defp parse_term([{:name, name} | _]),
    do: {:error, "#{name} must be called with an argument, e.g. #{name}(input)"}

  defp parse_term([token | _]), do: {:error, "unexpected #{describe(token)}"}
  defp parse_term([]), do: {:error, "expected an expression"}

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\r], do: tokenize(rest, acc)
  defp tokenize("--" <> _comment, acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize("++" <> rest, acc), do: tokenize(rest, [:concat | acc])
  defp tokenize("=" <> rest, acc), do: tokenize(rest, [:equals | acc])
  defp tokenize("(" <> rest, acc), do: tokenize(rest, [:open | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [:close | acc])
  defp tokenize("\"" <> rest, acc), do: string(rest, <<>>, acc)

  defp tokenize(<<c, _::binary>> = input, acc) when c in ?a..?z or c == ?_ do
    [name] = Regex.run(~r/\A[a-z_][a-zA-Z0-9_]*/, input)

    tokenize(binary_part(input, byte_size(name), byte_size(input) - byte_size(name)), [
      {:name, name} | acc
    ])
  end

  defp tokenize(<<c::utf8, _::binary>>, _acc), do: {:error, "unexpected character #{<<c::utf8>>}"}

  defp string("\"" <> rest, bytes, acc), do: tokenize(rest, [{:string, bytes} | acc])
  defp string("\\n" <> rest, bytes, acc), do: string(rest, bytes <> "\n", acc)
  defp string("\\\"" <> rest, bytes, acc), do: string(rest, bytes <> "\"", acc)
  defp string("\\\\" <> rest, bytes, acc), do: string(rest, bytes <> "\\", acc)
  defp string(<<c, rest::binary>>, bytes, acc), do: string(rest, <<bytes::binary, c>>, acc)
  defp string(<<>>, _bytes, _acc), do: {:error, "unterminated string"}

  defp describe({:name, name}), do: "`#{name}`"
  defp describe({:string, _}), do: "string"
  defp describe(:equals), do: "`=`"
  defp describe(:concat), do: "`++`"
  defp describe(:open), do: "`(`"
  defp describe(:close), do: "`)`"
end
