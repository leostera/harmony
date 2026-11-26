defmodule Harmony.MixProject do
  use Mix.Project

  def project do
    [
      app: :harmony,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Content-addressed functions for the BEAM",
      deps: deps(),
      elixirc_paths: elixirc_paths()
    ]
  end

  def application, do: [extra_applications: [:crypto, :logger]]

  # libbeam is opt-in: it needs a native host built from a libbeam checkout.
  defp deps do
    if libbeam?() do
      [
        {:libbeam_elixir,
         git: "https://github.com/leostera/midgard.git", sparse: "apps/libbeam_elixir"}
      ]
    else
      []
    end
  end

  defp elixirc_paths do
    if libbeam?(), do: ["lib", "runtime/libbeam"], else: ["lib"]
  end

  defp libbeam?, do: System.get_env("HARMONY_LIBBEAM") == "1"
end
