defmodule Relay.Mixfile do
  use Mix.Project

  def project do
    [app: :relay,
     version: "0.0.1",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     elixirc_options: [warnings_as_errors: System.get_env("ALLOW_WARNINGS") == nil],
     deps: deps,
     docs: docs]
  end

  def application do
    [applications: [:logger,
                    :emqttc]]
  end

  defp deps do
    [{:earmark, "~> 0.1", only: :dev},
     {:ex_doc, "~> 0.11", only: :dev},
     {:emqttc, github: "emqtt/emqttc", branch: "master"},
     {:enacl, github: "jlouis/enacl", tag: "0.14.0"}]
  end

  defp docs do
    [logo: "images/operable_docs_logo.png"]
  end
end
