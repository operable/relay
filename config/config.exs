use Mix.Config

config :logger, :console,
  metadata: [:module, :line],
  format: {Adz, :text}

config :carrier, credentials_dir: "/tmp/carrier_#{Mix.env}/credentials"

config :carrier, Carrier.Messaging.Connection,
  host: "127.0.0.1",
  port: 1883,
  log_level: :info

config :relay, data_root: Path.join([File.cwd!, "rt_data"])
config :relay, bundle_root: Path.join([File.cwd!, "bundles"])
config :relay, pending_bundle_root: Path.join([File.cwd!, "pending"])
config :relay, triage_bundle_root: Path.join([File.cwd!, "failed"])
config :relay, bundle_scan_interval_secs: 30

import_config "#{Mix.env}.exs"
