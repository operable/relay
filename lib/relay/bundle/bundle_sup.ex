defmodule Relay.Bundle.BundleSup do
  @moduledoc """
  Root supervisor for all bundles of commands running in a Relay.
  """

  use Supervisor
  use Relay.Logging

  def start_link(),
    do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init([]) do
    # children = [supervisor(Relay.Bundle.BundleCatalog, []),
    #             worker(Relay.Bundle.BundleLoader, [])]
    children = [worker(Relay.Bundle.BundleCatalog, []),
                worker(Relay.Bundle.Scanner, [])]
    ready(supervise(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 60))
  end

end
