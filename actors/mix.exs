defmodule Actors.MixProject do
  use Mix.Project

  def project do
    [
      app: :actors,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      build_embedded: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OLWSX.Actors.Application, []}
    ]
  end
end