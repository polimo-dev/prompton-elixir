defmodule PromptOnSDK.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/polimo-dev/prompton-elixir"

  def project do
    [
      app: :prompton_sdk,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "PromptOnSDK",
      description:
        "PromptOn Elixir SDK — fetch deployed use cases, render messages/text, and log provider calls.",
      package: package(),
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:solid, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Docs" => "https://docs.prompton.ai"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
