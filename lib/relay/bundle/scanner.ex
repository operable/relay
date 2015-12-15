defmodule Relay.Bundle.Scanner do

  use GenServer
  use Relay.Logging

  alias Relay.BundleFile
  alias Relay.Bundle.Catalog

  defstruct [:pending_path, :timer]

  @bundle_suffix ".loop"

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
    install_bundles(pending_bundle_files())
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
        case pending_bundle_files() do
          [] ->
            Logger.info("No pending bundles found.")
            ready({:ok, %__MODULE__{pending_path: pending_path}})
          _bundles ->
            Logger.info("Pending bundles will be installed shortly.")
            ready({:ok, %__MODULE__{pending_path: pending_path}})
        end
    end
  end

  defp scan_interval() do
    Application.get_env(:relay, :bundle_scan_interval_secs)
  end

  defp pending_bundle_files() do
    pending_path = Application.get_env(:relay, :pending_bundle_root)
    Path.wildcard(Path.join(pending_path, "*#{@bundle_suffix}"))
  end

  defp install_bundles([]) do
    :ok
  end
  defp install_bundles([bundle_path|t]) do
    install_bundle(bundle_path)
    install_bundles(t)
  end

  defp install_bundle(bundle_path) do
    Logger.info("Installing bundle #{bundle_path}.")
    case lock_bundle(bundle_path) do
      {:ok, locked_path} ->
        case activate_bundle(locked_path) do
          {:ok, installed_path} ->
            Logger.info("Bundle #{bundle_path} installed to #{installed_path} successfully.")
          _error ->
            Logger.info("Installation of bundle #{bundle_path} failed.")
        end
      error ->
        error
    end
  end

  defp activate_bundle(path) when is_binary(path) do
    case BundleFile.open(path) do
      {:ok, bf} ->
        activate_bundle(expand_bundle(bf))
      error ->
        Logger.error("Error opening locked bundle #{path}: #{inspect error}")
        error
    end
  end
  defp activate_bundle({:ok, bf}) do
    case register_bundle(bf) do
      :ok ->
        case BundleFile.unlock(bf) do
          {:ok, bf} ->
            BundleFile.close(bf)
            {:ok, bf.installed_path}
          error ->
            Logger.error("Error unlocking bundle #{bf.path}: #{inspect error}")
            cleanup_failed_activation(bf)
        end
      error ->
        Logger.error("Error registering bundle #{bf.path}: #{inspect error}")
        cleanup_failed_activation(bf)
    end
  end
  defp activate_bundle({error, bf}) do
    Logger.error("Error activating bundle #{bf.path}: #{inspect error}")
    cleanup_failed_activation(bf)
  end

  defp register_bundle(bf) do
    {:ok, config} = BundleFile.config(bf)
    bundle = Map.fetch!(config, "bundle")
    bundle_name = Map.fetch!(bundle, "name")
    commands = for command <- Map.fetch!(config, "commands") do
      name = Map.fetch!(command, "name")
      module = Map.fetch!(command, "module")
      {name, String.to_atom(module)}
    end
    case Catalog.install(bundle_name, commands, bf.installed_path) do
      :ok ->
        :ok
      error ->
        error
    end
  end

  defp cleanup_failed_activation(bf) do
    Catalog.uninstall(bf.name)
    install_dir = build_install_dir(bf)
    File.rm_rf(install_dir)
    triaged_path = build_triaged_path(bf)
    BundleFile.close(bf)
    File.rm(triaged_path)
    Logger.info("Triaging failed bundle to #{triaged_path}")
    File.rename(bf.path, triaged_path)
  end

  defp expand_bundle(bf) do
    install_dir = build_install_dir(bf)
    case File.exists?(install_dir) do
      # Bail here because we're already installed
      true ->
        {:ok, bf}
      false ->
        bundle_root = Application.get_env(:relay, :bundle_root)
        case BundleFile.expand_into(bf, bundle_root) do
          {:ok, bf} ->
            case File.dir?(install_dir) do
              true ->
                case BundleFile.verify_installed_files(bf) do
                  :ok ->
                    {:ok, bf}
                  {:failed, files} ->
                    files = Enum.join(files, "\n")
                    Logger.error("Bundle #{bf.path} contains corrupted files:\n#{files}")
                    {{:error, :corrupted_bundle}, bf}
                end
              _ ->
                Logger.error("Bundle #{bf.path} did not expand into expected install directory #{install_dir}")
                {{:error, :failed_expansion}, bf}
            end
          error ->
            {error, bf}
        end
    end
  end

  defp build_triaged_path(bf) do
    triage_root = Application.get_env(:relay, :triage_bundle_root)
    File.mkdir_p(triage_root)
    bundle_file_name = Path.basename(bf.path)
    |> String.replace(~r/.locked$/, "")
    Path.join(triage_root, bundle_file_name)
  end

  defp build_install_dir(bf) do
    {:ok, config} = BundleFile.config(bf)
    bundle = Map.fetch!(config, "bundle")
    name = Map.fetch!(bundle, "name")
    Path.join([Path.dirname(bf.path), name])
  end

  defp lock_bundle(bundle_path) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    locked_file = Path.basename(bundle_path) <> ".locked"
    locked_path = Path.join(bundle_root, locked_file)
    case File.regular?(locked_path) do
      true ->
        Logger.error("Error locking bundle #{bundle_path}: Locked bundle #{locked_path} already exists")
        {:error, :locked_bundle_exists}
      false ->
        case File.rename(bundle_path, locked_path) do
          :ok ->
            {:ok, locked_path}
          error ->
            Logger.error("Error locking bundle #{bundle_path}: #{inspect error}")
            error
        end
    end
  end

end
