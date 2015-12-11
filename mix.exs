defmodule Relay.Mixfile do
  use Mix.Project

  def project do
    [app: :relay,
     version: "0.0.1",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     elixirc_options: [warnings_as_errors: System.get_env("ALLOW_WARNINGS") == nil],
     deps: deps]
  end

  def application do
    [applications: [:logger,
                    :emqttc]]
  end

  defp deps do
    [{:emqttc, github: "emqtt/emqttc", branch: "master"}]
  end
end
