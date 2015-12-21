defmodule Relay.Announcer do

  defstruct [:meta_topic, :mq_conn, :backoff_factor, :state]

  use GenServer
  use Adz
  alias Carrier.Messaging
  alias Carrier.CredentialManager
  alias Carrier.Credentials
  alias Carrier.Signature

  @relays_discovery_topic "bot/relays/discover"
  @reconnect_interval 1000

  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    :erlang.process_flag(:trap_exit, true)
    # Seeding RNG to reduce chances of jitter lockstep across nodes
    :random.seed(:os.timestamp())
    case connect_to_bus() do
      {:ok, _conn} ->
        {:ok, creds} = CredentialManager.get()
        meta_topic = "bot/relays/#{creds.id}/meta"
        ready({:ok, %__MODULE__{meta_topic: meta_topic, backoff_factor: 1, state: :starting}})
      error ->
        Logger.error("Error starting #{__MODULE__}: #{inspect error}")
        error
    end
  end

  # MQTT connection dropped
  def handle_info({:EXIT, _, {:shutdown, reason}}, %__MODULE__{backoff_factor: bf}=state) do
    if reconnect?(reason) do
      Logger.info("#{translate(reason)}. Attempting to reconnect.")
      :timer.sleep(wait_interval(bf))
      connect_to_bus()
      {:noreply, %{state | backoff_factor: next_backoff_factor(bf)}}
    else
      exit({:shutdown, reason})
    end
  end
  def handle_info({:mqttc, conn, :connected}, %__MODULE__{meta_topic: topic}=state) do
    Logger.info("#{__MODULE__} connected.")
    Messaging.Connection.subscribe(conn, topic)
    case state.state do
      :starting ->
        :timer.send_after(10000, :announce)
      :started ->
        send(self(), :announce)
    end
    {:noreply, %{state | mq_conn: conn, backoff_factor: 1, state: :started}}
  end
  def handle_info({:publish, topic, message}, %__MODULE__{meta_topic: topic}=state) do
    case Poison.decode!(message) do
      %{"data" => %{"intro" => %{"id" => id,
                                 "role" => "bot",
                                  "public_key" => public_key}}} ->
        creds = %Credentials{id: id, public: Base.decode16!(public_key, case: :lower)}
        case CredentialManager.store(creds) do
          :ok ->
            Logger.info("Stored Cog bot public key: #{creds.id}")
          {:error, _} ->
            Logger.info("Ignoring Cog bot public key: #{creds.id}")
        end
        {:noreply, state}
      wtf ->
        IO.puts "#{inspect wtf}"
        {:noreply, state}
    end
  end
  def handle_info(:announce, state) do
    send_introduction(state)
    send_announcement(state)
    {:noreply, state}
  end
  def handle_info(msg, state) do
    IO.puts "#{inspect msg}"
    {:noreply, state}
  end

  defp translate(:econnrefused) do
    "MQTT connection refused"
  end
  defp translate(:tcp_closed) do
    "MQTT connection closed"
  end
  defp reconnect?(reason) when reason in [:econnrefused, :tcp_closed] do
    true
  end
  defp reconnect?(_), do: false

  defp last_will() do
    {:ok, creds} = CredentialManager.get()
    [topic: @relays_discovery_topic,
     qos: 1,
     retain: false,
     payload: Poison.encode!(Signature.sign(creds, %{announce: %{relay: creds.id, online: false}}))]
  end

  defp send_announcement(state) do
    {:ok, creds} = CredentialManager.get()
    announce = %{announce: %{relay: creds.id, online: true}}
    Messaging.Connection.publish(state.mq_conn, announce, routed_by: @relays_discovery_topic)
    {:noreply, state}
  end

  defp send_introduction(%__MODULE__{meta_topic: topic}=state) do
    {:ok, creds} = CredentialManager.get()
    intro = %{intro: %{relay: creds.id, public_key: Base.encode16(creds.public, case: :lower),
                       reply_to: topic}}
    Messaging.Connection.publish(state.mq_conn, intro, routed_by: @relays_discovery_topic)
  end

  defp wait_interval(backoff_factor) do
    jitter = :random.uniform(3000)
    interval = @reconnect_interval * backoff_factor
    if :random.uniform() > 0.6 do
      if jitter >= interval do
        :erlang.round(interval * 0.75)
      else
        interval - jitter
      end
    else
      interval + jitter
    end
  end

  defp next_backoff_factor(1) do
    2
  end
  defp next_backoff_factor(2) do
    4
  end
  defp next_backoff_factor(4) do
    10
  end
  defp next_backoff_factor(10) do
    20
  end
  defp next_backoff_factor(_) do
    30
  end

  defp connect_to_bus() do
    Messaging.Connection.connect([will: last_will()])
  end
end
