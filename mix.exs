Code.load_file(Path.join([__DIR__, "config", "helpers.exs"]))

defmodule Relay.Mixfile do
  use Mix.Project

  def project do
    [app: :relay,
     version: "0.2.0",
     elixir: "~> 1.2",
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
                    :logger,
                    :logger_file_backend,
                    :yaml_elixir,
                    :spanner] |> maybe_add_test_apps,
     mod: {Relay, []}]
  end

  # If we're starting for tests, we need an emqtt bus running as
  # well. Requires appropriate config to be set in config/test.exs
  defp test_apps do
    [:esockd,
     :emqttd]
  end

  defp maybe_add_test_apps(apps) do
    case Mix.env do
      :test ->
        apps
        |> Enum.concat(test_apps)
      _ ->
        apps
    end
  end

  defp deps do
    [{:logger_file_backend, github: "onkel-dirtus/logger_file_backend", ref: "457ce74fc242261328f71a77d75252bf0c74c170"},

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
     #
     # This is also how we get poison and uuid, BTW.
     {:spanner, github: "operable/spanner", ref: "5f1315578602041ae780fac50e6d492ee9010a87"},

     # For yaml parsing. yaml_elixir is a wrapper around yamerl which is a native erlang lib.
     {:yaml_elixir, "~> 1.0.0"},
     {:yamerl, github: "yakaz/yamerl"},

     # Same as Cog uses, and only for test, as a way to get around
     # Mix's annoying habit of starting up the application before
     # running ExUnit; Relay will not start unless there is a message
     # bus to connect to.
     {:emqttd, github: "operable/emqttd", branch: "tweaks-for-upstream", only: :test},

     {:earmark, "~> 0.2.1", only: :dev},
     {:ex_doc, "~> 0.11.4", only: :dev},
     {:mix_test_watch, "~> 0.2.5", only: :dev}]
  end

  defp docs do
    [logo: "images/operable_docs_logo.png",
     extras: ["design/bot_shell_protocol.md": [title: "Cog Relay Protocol"]]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

end
