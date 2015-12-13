defmodule Relay.Bundle.BundleCatalog do
  @moduledoc """
  Supervisor for all bundles of commands and services managed by the
  bot. Each child process is itself a supervisor of a single bundle.

  This supervisor is a simple one-for-one, as bundles of commands and
  services may be added to a running system at any time.

  """

  use Supervisor
  use Relay.Logging

  def start_link(),
    do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    children = [supervisor(Relay.Bundle.BundleSup, [])]
    ready(supervise(children, strategy: :simple_one_for_one, max_restarts: 10, max_seconds: 60))
  end

  @doc """
  Start up a new bundle under this supervisor.

  ## Arguments

    * `bundle` - Not quite sure what this should be yet; a `Bundle`
      model? The name of a bundle? Something else? See
      `Relay.Bundle.BundleSup.init/1`.

  """
  def load_bundle(bundle) do
    Logger.info("#{__MODULE__}: Loading bundle #{bundle.name}")
    Supervisor.start_child(__MODULE__, [bundle])
  end

  # TODO: Need `unload_bundle/1`, too?

end
