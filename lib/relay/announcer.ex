defmodule Relay.Announcer do

  @type state :: %__MODULE__{meta_topic: String.t,
                             mq_conn: Carrier.Messaging.Connection.connection}
  defstruct [:meta_topic,
             :mq_conn]

  use GenServer
  use Adz

  alias Carrier.CredentialManager
  alias Carrier.Credentials
  alias Carrier.Messaging.Connection
  alias Carrier.Signature
  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Runner

  @relays_discovery_topic "bot/relays/discover"
  @reconnect_interval 1000

  def start_link(),
    do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def announce(name, config),
    do: GenServer.call(__MODULE__, {:announce, name, config}, :infinity)

  def init(_) do
    # Trap exits of the bus connection process
    :erlang.process_flag(:trap_exit, true)

    case connect_to_bus() do
      {:ok, conn} ->
        {:ok, creds} = CredentialManager.get()
        meta_topic = "bot/relays/#{creds.id}/meta"

        Connection.subscribe(conn, meta_topic)

        start_bundles
        send_introduction(creds, conn, meta_topic)
        send_snapshot_announcement(creds, conn)

        ready({:ok, %__MODULE__{meta_topic: meta_topic, mq_conn: conn}})
      error ->
        Logger.error("Error starting #{__MODULE__}: #{inspect error}")
        {:stop, error}
    end
  end

  def handle_call({:announce, name, config}, _from, state),
    do: {:reply, send_bundle_announcement(name, config, state), state}
  def handle_call(_, _from, state),
    do: {:reply, :ignored, state}

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
  def handle_info({:EXIT, conn, reason} , %__MODULE__{mq_conn: conn}=state) do
    Logger.error("Message bus connection dropped; shutting down: #{inspect reason}")
    # Wait a bit to allow supervisior-mediated restarts to have a
    # chance of reconnecting
    :timer.sleep(2000) # 2 seconds
    {:stop, reason, state}
  end
  def handle_info(_msg, state),
    do: {:noreply, state}

  defp start_bundles do
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

  defp send_bundle_announcement(name, bundle, state) do
    {:ok, creds} = CredentialManager.get()
    announce = %{announce:
                 %{relay: creds.id,
                   online: true,
                   bundles: [bundle],
                   snapshot: false}}
    Connection.publish(state.mq_conn, announce, routed_by: @relays_discovery_topic)
    Logger.info("Sent announcement for bundle #{name}")
  end

  defp send_snapshot_announcement(creds, conn) do
    {:ok, bundles} = Catalog.all_bundles()
    bundles = Enum.map(bundles, fn({_, %{config: config}}) -> config end)
    announce = %{announce:
                 %{relay: creds.id,
                   online: true,
                   bundles: bundles,
                   snapshot: true}}
    Connection.publish(conn, announce, routed_by: @relays_discovery_topic)
    Logger.info("Bundle snapshot sent. Bundle count: #{length(bundles)}")
  end

  defp send_introduction(creds, conn, meta_topic) do
    Connection.publish(conn,
                       %{intro: %{relay: creds.id,
                                  public_key: Base.encode16(creds.public, case: :lower),
                                  reply_to: meta_topic}},
                       routed_by: @relays_discovery_topic)
  end

  defp connect_to_bus(),
    do: Connection.connect([will: last_will()])

  defp last_will() do
    {:ok, creds} = CredentialManager.get()

    message = %{announce:
                %{relay: creds.id,
                  online: false,
                  bundles: [],
                  snapshot: true}}

    signed_payload = creds
    |> Signature.sign(message)
    |> Poison.encode!

    [topic: @relays_discovery_topic,
     qos: 1,
     retain: false,
     payload: signed_payload]
  end


end
