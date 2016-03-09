defmodule Relay.Bundle.Runner do
  @moduledoc """
  Supervisor for all bundles of commands managed by a Relay instance.
  Each child process is itself a supervisor of a single bundle.

  This supervisor is a simple one-for-one, as bundles may be added to
  a running system at any time.

  """

  use Supervisor
  use Adz

  def start_link(),
    do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    children = [supervisor(Relay.Bundle.Sup, [])]
    ready(supervise(children, strategy: :simple_one_for_one, max_restarts: 10, max_seconds: 60))
  end

  @doc """
  Shutdown the supervision tree for the given bundle.
  """
  def stop_bundle(bundle_name) do
    # TODO: have this process create the name instead?
    process_name = Relay.Bundle.Sup.supervisor_name(bundle_name)
    case Process.whereis(process_name) do
      nil ->
        Logger.error("Could not find process #{process_name}!")
        {:error, :not_found}
      pid ->
        :ok = Supervisor.terminate_child(__MODULE__, pid)
        Logger.info("Terminated `#{process_name}` supervisor for bundle `#{bundle_name}`")
        :ok
    end
  end

  @doc """
  Start up a new bundle under this supervisor.
  """
  def start_bundle(name, installed_path) do
    bundle_dir = if String.ends_with?(installed_path, Spanner.skinny_bundle_extension()) do
      Path.join("/tmp", name)
    else
      installed_path
    end
    Supervisor.start_child(__MODULE__, [[bundle: name, foreign: bundle_dir]])
  end

end
