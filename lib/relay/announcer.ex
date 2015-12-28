defmodule Relay.Announcer do

  defstruct [:meta_topic, :mq_conn, :backoff_factor, :state]

  use GenServer
  use Adz
  alias Carrier.Messaging
  alias Carrier.CredentialManager
  alias Carrier.Credentials
  alias Carrier.Signature
  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Runner

  @relays_discovery_topic "bot/relays/discover"
  @reconnect_interval 1000

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def announce(name, config) do
    GenServer.call(__MODULE__, {:announce, name, config}, :infinity)
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

  def handle_call({:announce, name, config}, _from, %__MODULE__{state: :announced}=state) do
    {:reply, send_bundle_announcement(name, config, state), state}
  end
  def handle_call({:announce, name, _}, _from, state) do
    # We can safely skip announcing the bundle here since we send a complete listing of all commands
    # when transitioning to the `announced` state
    Logger.info("Delaying announcement of bundle #{name} until this Relay is connected to its upstream bot.")
    {:reply, :ok, state}
  end
  def handle_call(_, _from, state) do
    {:reply, :ignored, state}
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
  def handle_info({:mqttc, conn, :connected}, %__MODULE__{meta_topic: topic, state: state_name}=state) do
    Logger.info("#{__MODULE__} connected.")
    Messaging.Connection.subscribe(conn, topic)
    send(self(), :announce)
    state_name = if state_name == :starting do
      :started
    else
      state_name
    end
    {:noreply, %{state | mq_conn: conn, backoff_factor: 1, state: state_name}}
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
          {:error, :exists} ->
            :ok
          {:error, _}=error ->
            Logger.info("Ignoring Cog bot (#{creds.id}) public key: #{inspect error}")
        end
        {:noreply, state}
      _ ->
        {:noreply, state}
    end
  end
  def handle_info(:announce, state) do
    maybe_start_bundles(state)
    send_introduction(state)
    send_snapshot_announcement(state)
  end
  def handle_info(_msg, state) do
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
     payload: Poison.encode!(Signature.sign(creds, %{announce: %{relay: creds.id, online: false,
                                                                 bundles: [], snapshot: true}}))]
  end

  defp maybe_start_bundles(%__MODULE__{state: :started}) do
    Logger.info("Starting installed command bundles")
    for bundle <- Catalog.list_bundles() do
      installed_path = Catalog.installed_path(bundle)
      commands = Catalog.list_commands(bundle)
      case Runner.start_bundle(bundle, installed_path, commands) do
        {:ok, _} ->
          Logger.info("Bundle #{bundle} started")
        error ->
          Logger.error("Error starting bundle #{bundle}: #{inspect error}")
      end
    end
  end
  defp maybe_start_bundles(_) do
    :ok
  end

  defp send_bundle_announcement(name, bundle, state) do
    {:ok, creds} = CredentialManager.get()
    announce = %{announce: %{relay: creds.id, online: true, bundles: [bundle],
                             snapshot: false}}
    Messaging.Connection.publish(state.mq_conn, announce, routed_by: @relays_discovery_topic)
    Logger.info("Sent announcement for bundle #{name}")
  end

  defp send_snapshot_announcement(state) do
    {:ok, creds} = CredentialManager.get()
    {:ok, bundles} = Catalog.all_bundles()
    bundles = Enum.map(bundles, fn({_, %{config: config}}) -> config end)
    announce = %{announce: %{relay: creds.id, online: true, bundles: bundles, snapshot: true}}
    Messaging.Connection.publish(state.mq_conn, announce, routed_by: @relays_discovery_topic)
    Logger.info("Bundle snapshot sent. Bundle count: #{length(bundles)}")
    {:noreply, %{state | state: :announced}}
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
