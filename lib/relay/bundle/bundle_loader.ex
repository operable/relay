defmodule Relay.Bundle.BundleLoader do
  @moduledoc """
  Process that exists solely to start up all currently-recognized
  bundles at system start-up.
  """

  use GenServer
  require Logger
  alias Relay.Bundle.BundleCatalog
  alias Relay.Models.Bundle
  alias Relay.Repo

  def start_link(),
    do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    # If this proves to be too much work to do in `init`, we can fall
    # back to the "timeout=0" trick
    for bundle <- Repo.all(Bundle) do
      Logger.info("#{__MODULE__}: Preparing to load bundle '#{bundle.name}'")
      case BundleCatalog.load_bundle(bundle) do
        {:ok, pid} ->
          Logger.info("#{__MODULE__}: Loaded bundle '#{bundle.name}' at #{inspect pid}")
        {:error, {:already_started, pid}} ->
          Logger.warn("#{__MODULE__}: Not loading bundle '#{bundle.name}'; it was already loaded and running at #{inspect pid}")
      end
    end
    {:ok, []}
  end

end
