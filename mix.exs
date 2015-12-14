defmodule Relay.Mixfile do
  use Mix.Project

  def project do
    [app: :relay,
     version: "0.0.1",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     erlc_paths: ["lib/relay"],
     elixirc_paths: elixirc_paths(Mix.env),
     elixirc_options: [warnings_as_errors: System.get_env("ALLOW_WARNINGS") == nil],
     deps: deps,
     docs: docs]
  end

  def application do
    [applications: [:logger,
                    :emqttc],
     mod: {Relay, []}]
  end

  defp deps do
    [{:earmark, "~> 0.1", only: :dev},
     {:ex_doc, "~> 0.11", only: :dev},
     {:mix_test_watch, "~> 0.2", only: [:dev, :test]},
     {:emqttc, github: "emqtt/emqttc", branch: "master"},
     {:enacl, github: "jlouis/enacl", tag: "0.14.0"},
     {:poison, "~> 1.5.0"},
     {:uuid, "~> 1.0.1"}]
  end

  defp docs do
    [logo: "images/operable_docs_logo.png",
     extras: ["design/bot_shell_protocol.md": [title: "Cog Relay Protocol"]]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

end
