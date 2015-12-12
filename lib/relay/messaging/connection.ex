defmodule Relay.Messaging.Connection do

  alias Relay.Signature

  @moduledoc """
  Interface for the message bus on which commands communicate.
  """

  @default_log_level :error

  # Note: This type is what we get from emqttc; if we change
  # underlying message buses, we can just change this
  # definition. Client code can just depend on this opaque type and
  # not need to know that we're using emqttc at all.
  @typedoc "The connection to the message bus."
  @opaque connection :: pid()

  @doc """
  Starts up a message bus client process.

  Additionally, logging on this connection will be done at the level
  specified in application configuration under `:relay` -> `__MODULE__` -> `:log_level`.
  If that is not set, it defaults to the value specified in the attribute `@default_log_level`.

  """
  # Again, this spec is what comes from emqttc
  @spec connect() :: {:ok, connection()} | :ignore | {:error, term()}
  def connect() do
    opts = add_system_config([])
    :emqttc.start_link(opts)
  end

  def subscribe(conn, topic) do
    # `:qos1` is an MQTT quality-of-service level indicating "at least
    # once delivery" of messages. Additionally, the sender blocks
    # until receiving a message acknowledging receipt of the
    # message. This provides back-pressure for the system, and
    # generally makes things easier to reason about.
    #
    # See
    # http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718101
    # for more.
    :emqttc.subscribe(conn, topic, :qos1)
  end

  def unsubscribe(conn, topic) do
    :emqttc.unsubscribe(conn, topic)
  end

  @doc """
  Sign and publish a JSON object to the message bus.

  ## Keyword arguments

    * `:routed_by` - the topic on which to publish `object`. Required.
  """
  def sign_and_publish(conn, object, key, kw_args) when is_map(object) do
    signed = Signature.sign(object, key)
    publish(conn, Poison.encode!(signed), kw_args)
  end

  @doc """
  Publish a message to the message bus.

  ## Keyword Arguments

    * `:routed_by` - the topic on which to publish `message`. Required.

  ## Example

      publish(conn, "hello world", routed_by: "/really/interesting/stuff")

  """
  def publish(conn, message, kw_args) do
    topic = Keyword.fetch!(kw_args, :routed_by)
    :emqttc.publish(conn, topic, message)
  end

  defp add_system_config(opts) do
    opts
    |> add_connect_config
  end

  defp add_connect_config(opts) do
    connect_opts = Application.get_env(:loop, __MODULE__)
    host = Keyword.fetch!(connect_opts, :host)
    port = Keyword.fetch!(connect_opts, :port)
    log_level = Keyword.get(connect_opts, :log_level, @default_log_level)
    host = case is_binary(host) do
             true ->
               {:ok, addr} = :inet.parse_address(:erlang.binary_to_list(host))
               addr
             false ->
               host
           end
    [{:host, host}, {:port, port}, {:logger, {:lager, log_level}} | opts]
  end

end
