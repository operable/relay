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
  Start up a new bundle under this supervisor.
  """
  def start_bundle(name, installed_path, commands) do
    Supervisor.start_child(__MODULE__, [name, installed_path, commands])
  end

end