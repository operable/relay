defmodule Relay.Bundle.Scanner do

  use GenServer
  use Adz

  alias Relay.BundleFile
  alias Relay.Bundle.ElixirInstaller
  alias Relay.Bundle.ForeignInstaller
  alias Relay.Bundle.ForeignSkinnyInstaller
  alias Relay.Bundle.InstallHelpers, as: Helpers

  defstruct [:pending_path, :timer]

  def start_link(),
  do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def start_scanning() do
    GenServer.cast(__MODULE__, :start_scanning)
  end

  def init(_) do
    pending_path = Application.get_env(:relay, :pending_bundle_root)
    case File.exists?(pending_path) do
      false ->
        prepare_for_uploads(pending_path)
      true ->
        scan_for_uploads(pending_path)
    end
  end

  def handle_cast(:start_scanning, state) do
    send(self(), :scan)
    {:noreply, state}
  end
  def handle_cast(_, state) do
    {:noreply, state}
  end

  def handle_info(:scan, state) do
    install_bundles(pending_bundle_files() ++ pending_foreign_bundle_files())
    {:ok, timer} = :timer.send_after((scan_interval() * 1000), :scan)
    {:noreply, %{state | timer: timer}}
  end
  def handle_info(_, state) do
    {:noreply, state}
  end

  defp prepare_for_uploads(pending_path) do
    File.mkdir_p!(pending_path)
    ready({:ok, %__MODULE__{pending_path: pending_path}})
  end

  defp scan_for_uploads(pending_path) do
    case File.dir?(pending_path) do
      false ->
        Logger.error("Error starting bundle scanner: Upload path #{pending_path} is not a directory")
        {:error, :bad_pending_path}
      true ->
        if pending_files? do
          Logger.info("Pending bundles will be installed shortly.")
        else
          Logger.info("No pending bundles found.")
        end
        ready({:ok, %__MODULE__{pending_path: pending_path}})
    end
  end

  defp scan_interval() do
    Application.get_env(:relay, :bundle_scan_interval_secs)
  end

  defp pending_files? do
    length(pending_bundle_files()) > 0 or
    length(pending_foreign_bundle_files()) > 0
  end

  defp pending_bundle_files() do
    pending_path = Application.get_env(:relay, :pending_bundle_root)
    Path.wildcard(Path.join(pending_path, "*#{Spanner.bundle_extension()}"))
  end

  defp pending_foreign_bundle_files() do
    pending_path = Application.get_env(:relay, :pending_bundle_root)
    Path.wildcard(Path.join(pending_path, "*#{Spanner.skinny_bundle_extension()}"))
  end

  defp install_bundles([]) do
    :ok
  end
  defp install_bundles([bundle_path|t]) do
    try do
      cond do
        String.ends_with?(bundle_path, Spanner.bundle_extension()) ->
          install_bundle_file(bundle_path)
        String.ends_with?(bundle_path, Spanner.skinny_bundle_extension()) ->
          ForeignSkinnyInstaller.install(bundle_path)
      end
    rescue
      e ->
        Logger.error("Unexpected error occurred while installing bundle #{bundle_path}: #{inspect e}\n #{inspect System.stacktrace()}")
        Helpers.cleanup_failed_activation(bundle_path)
    end
    install_bundles(t)
  end

  defp install_bundle_file(bundle_path) do
    case BundleFile.open(bundle_path) do
      {:ok, bf} ->
        case BundleFile.config(bf) do
          {:ok, config} ->
            BundleFile.close(bf)
            bundle = config["bundle"]
            case config["bundle"]["type"] do
              "elixir" ->
                ElixirInstaller.install(bundle_path)
              nil ->
                ElixirInstaller.install(bundle_path)
              "foreign" ->
                ForeignInstaller.install(bundle_path)
            end
          error ->
            BundleFile.close(bf)
            Logger.error("Error extracting bundle config from #{bundle_path}: #{inspect error}")
        end
      error ->
        Logger.error("Error opening bundle #{bundle_path}: #{inspect error}")
    end
  end

end
