defmodule Relay.TopSupervisor do

  use Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, [])
  end

  def init(_) do
    children = [worker(Carrier.CredentialManager, []),
                worker(Relay.Announcer, []),
                supervisor(Relay.Bundle.BundleSup, [])]
    supervise(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 60)
  end

end
