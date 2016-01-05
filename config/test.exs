use Mix.Config

mqtt_host = "127.0.0.1"
mqtt_port = 1884

config :carrier, Carrier.Messaging.Connection,
  host: mqtt_host,
  port: mqtt_port,
  log_level: :info

config :emqttd, :access,
  auth: [anonymous: []],
  acl: [internal: [file: 'config/acl.conf', nomatch: :allow]]

config :emqttd, :broker,
  sys_interval: 60,
  retained: [max_message_num: 1024, max_payload_size: 65535],
  pubsub: [pool_size: 8]

config :emqttd, :mqtt,
  packet: [max_clientid_len: 128, max_packet_size: 163840],
  client: [ingoing_rate_limit: :'64KB/s', idle_timeout: 1],
  session: [max_inflight: 100, unack_retry_interval: 60,
            await_rel_timeout: 15, max_awaiting_rel: 0,
            collect_interval: 0, expired_after: 4],
  queue: [max_length: 100, low_watermark: 0.2, high_watermark: 0.6,
          queue_qos0: true],
  modules: [presence: [qos: 0]]

config :emqttd, :listeners,
[{:mqtt, mqtt_port, [acceptors: 16,
                     max_clients: 64,
                     access: [allow: :all],
                     sockopts: [backlog: 8,
                                ip: mqtt_host,
                                recbuf: 4096,
                                sndbuf: 4096,
                                buffer: 4096]]}]
