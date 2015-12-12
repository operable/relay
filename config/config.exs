use Mix.Config

config :relay, credentials_dir: "/tmp/relay_#{Mix.env}/credentials"

config :relay, Relay.Messaging.Connection,
  host: "127.0.0.1",
  port: 1883,
  log_level: :info
