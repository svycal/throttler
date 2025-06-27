defmodule Throttler.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :throttler,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      name: "Throttler",
      deps: deps(),
      description:
        "A lightweight DSL for throttling events with Postgres-backed persistence and race safety.",
      docs: docs(),
      package: package()
    ]
  end

  defp docs do
    [
      source_ref: "v#{@version}",
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.0"},
      {:ecto_sql, "~> 3.0"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Derrick Reimer"],
      licenses: ["MIT"],
      links: links()
    ]
  end

  def links do
    %{
      "GitHub" => "https://github.com/svycal/throttler",
      "Changelog" => "https://github.com/svycal/throttler/blob/v#{@version}/CHANGELOG.md",
      "Readme" => "https://github.com/svycal/throttler/blob/v#{@version}/README.md"
    }
  end
end
