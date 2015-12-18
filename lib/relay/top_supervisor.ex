defmodule Relay.TopSupervisor do

  use Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, [])
  end

  def init(_) do
    children = [worker(Carrier.CredentialManager, []),
                worker(Relay.Announcer, []),
                supervisor(Relay.Bundle.BundleSup, [])]
    supervise(children, strategy: :one_for_one)
  end

end
