defmodule Relay.Announcer do

  # Timeout after which an unacknowledged announcement is sent out
  # again.
  @ack_timeout 1500 # milliseconds

  # See moduledoc for info about this
  @default_bundle_announcement_flush_period 10000 # milliseconds

  @moduledoc """
  Announces to a Cog bot the existence of a Relay, as well as which
  bundles a Relay is currently serving.

  When the Announcer comes up, it first "introduces" itself to the Cog
  bot by sending its public key; this is the key with which all future
  messages from this Relay will be signed, and by which Cog will
  authenticate those messages. The bot, in turn, will send the
  Announcer _its_ public key, with which the Relay will authenticate
  all messages coming from the bot.

  With the introduction handshake out of the way, the Announcer will
  send a "snapshot" announcement to the bot. This is a single message
  containing information on all the bundles that the Relay currently
  knows about (e.g., everything that's been installed already). When
  the bot receives this snapshot message, it marks that particular
  Relay as knowing about those (and _only_ those) bundles. The bot
  will then send the Announcer an acknowledgment message. Until the
  Announcer receives this acknowledgment, it will continue to send
  snapshot messages periodically (every #{@ack_timeout} milliseconds);
  this provides robustness and consistency for the overall system when
  network splits occur.

  Once the Announcer has acknowledgment that the bot knows what
  bundles it currently has, the Announcer will shift to it's
  steady-state "announcing" mode. As new bundles are installed on the
  Relay instance, the Announcer will send an "increment" announcement
  to the bot, informing it of the new bundle(s) it knows about. The
  bot will then add these new bundles to its store of Relay -> bundle
  mappings.

  Instead of sending an announcement message immediately when a new
  bundle is installed, we batch up such announcements and send them
  out in a single message periodically (by default,
  every #{@default_bundle_announcement_flush_period}
  milliseconds). The intention is to provide a bit of back-pressure in
  the face of potential automated setups of Cog (think someone
  managing one or more Relays with Chef and installing 90 bundles in a
  rapid, automated fashion).

  This can be customized by the end user via `:relay ->
  :bundle_announcement_flush_period configuration.`

  This batching mechanism also provides the means to collect any
  bundle installations that may occur between the time the initial
  snapshot announcement is sent and when it is finally
  acknowledged. If any bundles are installed during that time, an
  increment announcement is sent out immediately after the snapshot
  has been acknowledged.

  Increment announcements are also re-sent until acknowledged by the
  bot, just like snapshot announcements, and at the same period.

  """

  require Relay.ConfigurationException

  @behaviour :gen_fsm

  # The message bus topic to which Announcer publishes its
  # announcements.
  @relays_discovery_topic "bot/relays/discover"

  # If we lose a network connection with the message bus, we'll delay
  # shutting down for a brief period in order to allow
  # supervisor-mediated restarts to have an effect. Otherwise, it's
  # possible to burn through all the restarts and end up shutting down
  # for a brief network hiccup.
  @disconnection_shutdown_delay 2000 # milliseconds

  @type bundle_config :: map()
  @type announcement_id :: binary()
  @type in_flight_entry :: %{bundles: [bundle_config()],
                             timer_ref: reference()}

  @typedoc """
  FSM loop data

  * `mq_conn`: message bus client
  * `topic`: message bus topic to which the FSM listens for
    messages
  * `in_flight`: records information about currently in-flight
    announcements (announcements that have been sent, but not yet
    acknowledged)
  * `pending`: records information about announcements that have yet
    to be sent out because the FSM was not in the appropriate state at
    the time the announcement request was made.
  * `flush_period`: the amount of time between bundle announcement
    flushes. Defaults
    to #{@default_bundle_announcement_flush_period} milliseconds.
  * `flush_timer`: reference to the timer that triggers the next
    announcement flush.
  """
  @type loop_data :: %__MODULE__{mq_conn: Carrier.Messaging.Connection.connection(),
                                 topic: String.t,
                                 in_flight: %{announcement_id() => in_flight_entry()},
                                 pending: [bundle_config()],
                                 flush_period: non_neg_integer(),
                                 flush_timer: :erlang.reference()}
  defstruct [mq_conn: nil,
             topic: "",
             in_flight: %{},
             pending: [],
             flush_period: @default_bundle_announcement_flush_period,
             flush_timer: nil]

  use Adz

  alias Carrier.CredentialManager
  alias Carrier.Credentials
  alias Carrier.Messaging.Connection
  alias Carrier.Signature
  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Triage

  def start_link(),
    do: :gen_fsm.start_link({:local, __MODULE__}, __MODULE__, [], [])

  @doc """
  Announce the presence of a single new bundle. This is the main
  external API of #{inspect __MODULE__}.

  `bundle_config` a bundle's `config.json` metadata file as a map.
  """
  @spec announce(bundle_config()) :: :ok
  def announce(bundle_config),
    do: :gen_fsm.send_all_state_event(__MODULE__, {:announce, bundle_config})

  @doc """
  Trigger the sending of a new snapshot announcement.

  Commonly used after deleting a bundle from the Relay, in order to
  ensure that the bot has a consistent view of what the Relay
  currently provides. (This is in place of a "delete" announcement,
  which offers more ways to become inconsistent.)
  """
  def snapshot(),
    do: :gen_fsm.send_all_state_event(__MODULE__, :snapshot)

  @doc """
  Start up a new #{inspect __MODULE__} process.

  If a custom value for `:relay -> :bundle_announcement_flush_period`
  is being used, it is read here. Any changes to that configured value
  will be picked up when the process restarts.
  """
  def init([]) do
    # Trap exits of the bus connection process
    :erlang.process_flag(:trap_exit, true)

    flush_period = resolve_flush_period!

    case connect_to_bus() do
      {:ok, conn} ->
        {:ok, creds} = CredentialManager.get()
        topic = "bot/relays/#{creds.id}/announcer"
        Logger.debug("Subscribing to topic #{topic}")
        Connection.subscribe(conn, topic)

        loop_data = %__MODULE__{topic: topic,
                                mq_conn: conn,
                                flush_period: flush_period}

        ready({:ok, :introducing, loop_data, 0})
      error ->
        Logger.error("Error starting #{__MODULE__}: #{inspect error}")
        {:stop, error}
    end
  end

  def introducing(:timeout, loop_data) do
    introduction(loop_data.topic)
    |> publish(loop_data.mq_conn)

    {:next_state, :waiting_for_key, loop_data}
  end

  def snapshotting(:timeout, loop_data) do
    id = announcement_id
    bundles = current_bundles

    bundle_names = Enum.map(bundles, fn(%{"bundle" => %{"name" => name}}) -> name end)
    Logger.info("Sending snapshot for bundles: #{inspect bundle_names}")

    snapshot(loop_data.topic, id, bundles)
    |> publish(loop_data.mq_conn)

    maybe_transition_state({:snapshotting, :waiting_for_snapshot_ack}, mark_as_in_flight(loop_data, id, bundles))
  end

  def waiting_for_snapshot_ack({:retry_announcement, id}, %__MODULE__{in_flight: in_flight}=loop_data) do
    case Map.get(in_flight, id) do
      %{bundles: bundles} ->

        snapshot(loop_data.topic, id, bundles)
        |> publish(loop_data.mq_conn)

        {:next_state,
         :waiting_for_snapshot_ack,
         mark_as_in_flight(loop_data, id, bundles)}
      nil ->
        Logger.warn("Told to retry announcing a snapshot, but don't know about announcement ID: #{inspect id}")
        {:next_state, :waiting_for_snapshot_ack, loop_data}
    end
  end

  def announcing(event, %__MODULE__{pending: bundles}=loop_data) when event in [:timeout, :flush_pending] do
    case bundles do
      [] ->
        # We don't have any pending announcements to make this time
        # around; hit snooze on our alarm clock!
        loop_data = schedule_next_flush(loop_data)
        {:next_state, :announcing, loop_data}
      _ ->
        # We've accumulated some pending announcements; better send 'em out
        id = announcement_id

        increment(loop_data.topic, id, bundles)
        |> publish(loop_data.mq_conn)

        new_loop_data = loop_data
        |> mark_as_in_flight(id, bundles)
        |> clear_pending
        |> schedule_next_flush

        {:next_state, :announcing, new_loop_data}
    end
  end
  def announcing({:retry_announcement, id}, %__MODULE__{in_flight: in_flight}=loop_data) do
    if currently_in_flight?(loop_data, id) do
      %{bundles: bundles} = Map.fetch!(in_flight, id)

      increment(loop_data.topic, id, bundles)
      |> publish(loop_data.mq_conn)

      {:next_state, :announcing, mark_as_in_flight(loop_data, id, bundles)}
    else
      Logger.warn("Told to retry announcing an announcement, but don't know about announcement ID: #{inspect id}")
      {:next_state, :announcing, loop_data}
    end
  end

  def handle_info({:publish, topic, message}, state, %__MODULE__{topic: topic}=loop_data) when state in [:waiting_for_snapshot_ack, :announcing] do
    # We expect to receive acknowledgment messages both in our
    # waiting_for_snapshot_ack and announcing states. In both cases, a
    # successful receipt transitions us to :announcing. Unexpected
    # messages should leave us in whatever state we're currently in.

    case CredentialManager.verify_signed_message(message) do
      {true, %{"announcement_id" => id, "status" => status, "bundles" => failed_bundles}} ->
        if status == "failed", do: Triage.remove_bundles(failed_bundles)
        if currently_in_flight?(loop_data, id) do
          loop_data = mark_as_acknowledged(loop_data, id)
          maybe_transition_state({state, :announcing}, loop_data)
        else
          Logger.warn("Acknowledged announcement with ID #{inspect id}, but no record of such an announcement exists; perhaps Relay restarted?")
          {:next_state, state, loop_data}
        end
      {true, other} ->
        Logger.warn("Got unexpected message in state #{state}: #{inspect other}")
        {:next_state, state, loop_data}
      false ->
        Logger.warn("Failed message verification in state #{state} for message #{inspect message}")
        {:next_state, state, loop_data}
    end
  end
  def handle_info({:publish, topic, message}, :waiting_for_key, %__MODULE__{topic: topic}=loop_data) do
    # We don't use CredentialManager.verify_signed_message/1 here
    # because we're waiting for the key from the bot!
    case Poison.decode!(message) do
      %{"data" => %{"intro" => %{"id" => id,
                                 "role" => "bot",
                                 "public_key" => public_key}}} ->
        Logger.info("Received bot key #{inspect public_key}; registering with CredentialManager")

        creds = %Credentials{id: id, public: Base.decode16!(public_key, case: :lower)}
        case CredentialManager.store(creds) do
          :ok ->
            Logger.info("Stored Cog bot public key: #{creds.id}")
          {:error, :exists} ->
            # It's a bot we already know about (e.g., we've restarted
            # and are connecting with the bot we've connected with in
            # the past).
            :ok
          {:error, _}=error ->
            Logger.info("Ignoring Cog bot (#{creds.id}) public key: #{inspect error}")
        end
        maybe_transition_state({:waiting_for_key, :snapshotting}, loop_data)
      other ->
        Logger.warn("Received unexpected message in :waiting_for_key state: #{inspect other}")
        {:next_state, :waiting_for_key, loop_data}
    end
  end
  def handle_info({:EXIT, conn, reason}, _state, %__MODULE__{mq_conn: conn}=loop_data) do
    Logger.error("Message bus connection dropped; shutting down: #{inspect reason}")
    :timer.sleep(@disconnection_shutdown_delay)
    {:stop, {:connection_dropped, reason}, loop_data}
  end
  def handle_info(_message, state, loop_data),
    do: {:next_state, state, loop_data}

  def handle_event({:announce, config}, state, %__MODULE__{pending: pending}=loop_data),
    do: {:next_state, state, %{loop_data | pending: [config | pending]}}
  def handle_event(:snapshot, _state, loop_data) do
    # Any pending and in-flight announcements will necessarily be
    # subsumed by the snapshot.
    #
    # Additionally, we want to cancel any pending flush, since it's
    # otherwise possible that we could end up with multiple pending
    # flushes, accumulating them with each new triggered snapshot.
    loop_data = loop_data
    |> clear_pending
    |> cancel_all_in_flight
    |> cancel_next_flush

    {:next_state, :snapshotting, loop_data, 0}
  end


  def handle_sync_event(_event, _from, state_name, loop_data),
    do: {:reply, :ignored, state_name, loop_data}

  def code_change(_old_vsn, state_name, loop_data, _extra),
    do: {:ok, state_name, loop_data}

  def terminate(_reason, _state_name, _loop_data),
    do: :ok

  ########################################################################

  # If the user has configured a custom bundle announcement flush
  # period, look up that value, ensuring that it is valid. Otherwise,
  # use the default value.
  defp resolve_flush_period! do
    case Application.get_env(:relay, :bundle_announcement_flush_period) do
      nil ->
        Logger.info("Configuration not found for :relay -> :bundle_announcement_flush_period; using default value of #{@default_bundle_announcement_flush_period} ms")
        @default_bundle_announcement_flush_period
      value when is_integer(value) ->
        Logger.info("Using configured :relay -> :bundle_announcement_flush_period value of #{value} ms")
        value
      bad_value ->
        raise Relay.ConfigurationException.new("Expected integer for configuration :relay -> :bundle_announcement_flush_period, but found #{inspect bad_value} instead")
    end
  end

  defp current_bundles do
    {:ok, bundles} = Catalog.all_bundles()
    bundles
    |> Enum.map(fn({_, %{config: config}}) -> config end)
  end

  defp schedule_next_flush(%__MODULE__{flush_period: period}=loop_data) do
    ref = :gen_fsm.send_event_after(period, :flush_pending)
    %{loop_data | flush_timer: ref}
  end

  defp cancel_next_flush(%__MODULE__{flush_timer: ref}=loop_data) when is_reference(ref) do
    :gen_fsm.cancel_timer(ref)
    %{loop_data | flush_timer: nil}
  end

  defp publish(message, conn),
    do: Connection.publish(conn, message, routed_by: @relays_discovery_topic)

  # See `mark_as_acknowledged/2` for this function's inverse.
  defp mark_as_in_flight(%__MODULE__{in_flight: in_flight}=loop_data, announcement_id, bundles) do
    updated = Map.put(in_flight, announcement_id, %{bundles: bundles,
                                                    timer_ref: new_retry_timer_for(announcement_id)})
    %{loop_data | in_flight: updated}
  end

  defp new_retry_timer_for(announcement_id),
    do: :gen_fsm.send_event_after(@ack_timeout, {:retry_announcement, announcement_id})

  defp currently_in_flight?(%__MODULE__{in_flight: in_flight}, announcement_id),
    do: Map.has_key?(in_flight, announcement_id)

  # See `mark_as_in_flight/3` for this function's inverse.
  defp mark_as_acknowledged(%__MODULE__{in_flight: in_flight}=loop_data, announcement_id) do
    %{timer_ref: ref} = Map.fetch!(in_flight, announcement_id)
    :gen_fsm.cancel_timer(ref)
    %{loop_data | in_flight: Map.delete(in_flight, announcement_id)}
  end

  # When we send a triggered snapshot (as opposed to the initial one
  # sent at startup), we need to cancel all pending retry timers for
  # currently in-flight announcements. We don't care to retry them, as
  # we're going to be sending a snapshot, which will subsume those
  # announcements anyway.
  defp cancel_all_in_flight(%__MODULE__{in_flight: in_flight}=loop_data),
    do: Enum.reduce(Map.keys(in_flight), loop_data, &mark_as_acknowledged(&2, &1))

  # Empty the list of pending bundles to announce; done after each
  # flush
  defp clear_pending(%__MODULE__{}=loop_data),
    do: %{loop_data | pending: []}

  # A unique identifier for an announcement. Used to correlate
  # acknowledgements with the corresponding announcement so we know
  # which ones to not retransmit.
  defp announcement_id,
    do: UUID.uuid4(:hex)

  # Create a snapshot announcement body
  defp snapshot(topic, id, configs),
    do: announcement(:snapshot, topic, id, configs)

  # Create an increment announcement body
  defp increment(topic, id, configs),
    do: announcement(:increment, topic, id, configs)

  defp announcement(announcement_type, topic, id, configs) do
    {:ok, creds} = CredentialManager.get
    is_snapshot = case announcement_type do
                    :snapshot -> true
                    :increment -> false
                  end

    %{announce: %{relay: creds.id,
                  online: true,
                  bundles: List.wrap(configs),
                  snapshot: is_snapshot,
                  reply_to: topic,
                  announcement_id: id}}
  end

  # TODO: Perhaps we should add an announcement ID here and have the bot
  # send it back to us, so we can have more confidence that the key
  # we're getting is from someplace quasi-trustworthy?
  defp introduction(topic) do
    {:ok, creds} = CredentialManager.get
    %{intro: %{relay: creds.id,
               public_key: Base.encode16(creds.public, case: :lower),
               reply_to: topic}}
  end

  defp connect_to_bus(),
    do: Connection.connect([will: last_will()])

  # Defines a payload to send out when the message bus connection
  # closes; ensures that the bot is notified if this Relay goes
  # offline so it can update itself accordingly.
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

  # Basic infrastructure for checking loop_data invariants at state
  # transition points
  defp maybe_transition_state({from_state, to_state}=transition, loop_data) when transition in [{:waiting_for_snapshot_ack, :announcing},
                                                                                                {:waiting_for_key, :snapshotting}] do
    if no_in_flight_announcements?(loop_data) do
      # In both transition cases, going to either :announcing or
      # :snapshotting, we want to trigger an immediate timeout event.
      #
      # In the transition to announcing, we want to immediately flush
      # any pending announcements.
      #
      # In the transition to snapshotting, we're using the timeout=0
      # trick to directly drive the progression between states instead
      # of relying on external events to do so.
      {:next_state, to_state, loop_data, 0}
    else
      Logger.error("FSM invariant not met transitioning from :waiting_for_snapshot_ack -> :announcing; there should be no other in-flight announcements, but there were: #{inspect loop_data.in_flight}")
      {:stop,
       {:invariant_not_met, from_state, to_state, :in_flight_announcements},
       loop_data}
    end
  end
  defp maybe_transition_state({current_state, current_state}, loop_data),
    # If we're staying in the same state, then just stay in the same state!
    do: {:next_state, current_state, loop_data}
  defp maybe_transition_state({_from_state, to_state}, loop_data),
    do: {:next_state, to_state, loop_data}

  # loop data invariant predicate
  defp no_in_flight_announcements?(loop_data),
    do: loop_data.in_flight == %{}
end
