use Mix.Config

config :relay, credentials_dir: "/tmp/relay_#{Mix.env}/credentials"

config :relay, Relay.Messaging.Connection,
  host: "127.0.0.1",
  port: 1883,
  log_level: :info

config :relay, bundle_root: Path.join([File.cwd!, "bundles"])
config :relay, bundle_upload_root: Path.join([File.cwd!, "bundle_uploads"])
config :relay, bundle_scan_interval_secs: 30
