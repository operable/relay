defmodule Relay.Bundle.Starter do
  @moduledoc """
  Process that exists solely to start up all currently-recognized
  bundles at system start-up.
  """

  # GenServer might be a bit overkill for this, admittedly.
  use GenServer
  use Adz

  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Runner

  def start_link(),
    do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init([]) do
    Logger.info("Starting installed command bundles")
    for bundle <- Catalog.list_bundles() do
      installed_path = Catalog.installed_path(bundle)
      start_fn = if foreign_bundle?(installed_path) do
        &Runner.start_foreign_bundle/2
      else
        &Runner.start_bundle/2
      end
      case start_fn.(bundle, installed_path) do
        {:ok, _} ->
          Logger.info("Bundle #{bundle} started")
        {:error, reason} ->
          Logger.error("Error starting bundle #{bundle}: #{inspect reason}")
      end
    end
    # TODO: error out instead of anything failed to come up?
    :ignore
  end

  defp foreign_bundle?(path) do
    ebin_dir = Path.join(path, "ebin")
    String.ends_with?(path, ".json") or File.dir?(ebin_dir) == false
  end

end
