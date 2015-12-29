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
    [applications: [:crypto,
                    :logger],
     mod: {Relay, []}]
  end

  defp deps do
    [{:earmark, "~> 0.1", only: :dev},
     {:ex_doc, "~> 0.11", only: :dev},
     {:mix_test_watch, "~> 0.2", only: [:dev, :test]},
     {:emqttc, github: "emqtt/emqttc", branch: "master"},
     {:adz, git: "git@github.com:operable/adz", ref: "07ba970e0bec955f1f3ed1c4771511139924c7fd"},
     {:poison, "~> 1.5.0"},
     {:uuid, "~> 1.0.1"},

     # Though we do not explicitly use Spanner in Relay, we provide it
     # as a runtime dependency for command bundles.
     #
     # Also, while we do use Carrier directly in Relay, it is a
     # dependency of spanner, so we'll take the version Spanner
     # depends on, rather than explicitly listing it. This ensures
     # that we have compatible versions without manual maintenance.
     #
     # Ditto for Piper (a dependency of spanner and runtime dependency
     # of bundles).
     {:spanner, git: "git@github.com:operable/spanner", ref: "8147943a4079930620c5e3a243c73af8681b901d"}
    ]
  end

  defp docs do
    [logo: "images/operable_docs_logo.png",
     extras: ["design/bot_shell_protocol.md": [title: "Cog Relay Protocol"]]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

end
