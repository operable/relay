use Mix.Config
use Relay.Config.Helpers

# ========================================================================
# Relay Paths

# NOTE: The data_dir function generates a path to a sub-directory
# relative to the $RELAY_DATA_DIR environment variable or to
# <relay root>/data if $RELAY_DATA_DIR is not defined.

config :relay, data_root: data_dir("rt_data")
config :relay, bundle_root: data_dir("bundles")
config :relay, pending_bundle_root: data_dir("pending")
config :relay, triage_bundle_root: data_dir("failed")
config :relay, bundle_scan_interval_secs: 30

config :spanner, :command_config_root, data_dir("command_config")

# ========================================================================
# MQTT Messaging

config :carrier, Carrier.Messaging.Connection,
  host: System.get_env("COG_MQTT_HOST") || "127.0.0.1",
  port: ensure_integer(System.get_env("COG_MQTT_PORT")) || 1883,
  log_level: :info

config :carrier, credentials_dir: data_dir("carrier_credentials")

# ========================================================================
# Logging

log_opts = [metadata: [:module, :line], format: {Adz, :text}]

config :logger,
  backends: [:console, {LoggerFileBackend, :relay_log}],
  console: log_opts,
  relay_log: log_opts ++ [path: data_dir("relay.log")]


import_config "#{Mix.env}.exs"
