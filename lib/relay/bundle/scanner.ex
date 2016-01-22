defmodule Relay.Bundle.Scanner do

  use GenServer
  use Adz

  alias Spanner.Bundle.ConfigValidator
  alias Relay.BundleFile
  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Runner
  alias Relay.Announcer

  defstruct [:pending_path, :timer]

  @foreign_bundle_suffix ".json"

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
          Logger.info("No pending Elixir or foreign bundles found.")
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
    Path.wildcard(Path.join(pending_path, "*#{@foreign_bundle_suffix}"))
  end

  defp install_bundles([]) do
    :ok
  end
  defp install_bundles([bundle_path|t]) do
    cond do
      String.ends_with?(bundle_path, Spanner.bundle_extension()) ->
        install_elixir_bundle(bundle_path)
      String.ends_with?(bundle_path, @foreign_bundle_suffix) ->
        install_foreign_bundle(bundle_path)
    end
    install_bundles(t)
  end

  defp install_elixir_bundle(bundle_path) do
    Logger.info("Installing Elixir bundle #{bundle_path}.")
    case lock_bundle(bundle_path) do
      {:ok, locked_path} ->
        case activate_bundle(locked_path) do
          {:ok, installed_path} ->
            Logger.info("Elixir Bundle #{bundle_path} installed to #{installed_path} successfully.")
          _error ->
            Logger.info("Installation of Elixir bundle #{bundle_path} failed.")
        end
      error ->
        error
    end
  end

  defp install_foreign_bundle(bundle_path) do
    case File.read(bundle_path) do
      {:ok, contents} ->
        case Poison.decode(contents) do
          {:ok, config} ->
            case ConfigValidator.validate(config) do
              :ok ->
                installed_path = installed_foreign_path(bundle_path)
                bundle_name = config["bundle"]["name"]
                case File.rename(bundle_path, installed_path) do
                  :ok ->
                    case Catalog.install(config, installed_path) do
                      :ok ->
                        case Runner.start_foreign_bundle(bundle_name, installed_path) do
                          {:ok, _} ->
                            case Announcer.announce(config) do
                              :ok ->
                                {:ok, installed_path}
                                Logger.info("Foreign bundle #{bundle_path} installed to #{installed_path} successfully.")
                              error ->
                                Logger.error("Error launching foreign bundle #{bundle_path}: #{inspect error}")
                                cleanup_failed_activation(bundle_path, bundle_name)
                            end
                          error ->
                            Logger.error("Error launching foreign command bundle: #{bundle_path}: #{inspect error}")
                            cleanup_failed_activation(bundle_path, bundle_name)
                        end
                      error ->
                        Logger.error("Error installing foreign bundle #{bundle_path}: #{inspect error}")
                        cleanup_failed_activation(bundle_path, bundle_name)
                    end
                  error ->
                    Logger.error("Error moving foreign bundle #{bundle_path} into place: #{inspect error}")
                    cleanup_failed_activation(bundle_path, bundle_name)
                end
              {:error, {_reason, _field, message}} ->
                Logger.error("Error validating #{bundle_path}: #{message}")
                cleanup_failed_activation(bundle_path)
            end
          error ->
            Logger.error("Error parsing foreign bundle #{bundle_path} as JSON: #{inspect error}")
            cleanup_failed_activation(bundle_path)
        end
      error ->
        Logger.error("Error reading foreign bundle #{bundle_path} contents: #{inspect error}")
        cleanup_failed_activation(bundle_path)
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
            case Runner.start_bundle(bf.name, bf.installed_path) do
              {:ok, _} ->
                BundleFile.close(bf)
                {:ok, config} = Catalog.bundle_config(bf.name)
                case Announcer.announce(config) do
                  :ok ->
                    {:ok, bf.installed_path}
                  error ->
                    Logger.error("Error announcing bundle #{bf.path} to upstream bot: #{inspect error}")
                    cleanup_failed_activation(bf)
                end
              error ->
                Logger.error("Error starting bundle #{bf.path}: #{inspect error}")
                cleanup_failed_activation(bf)
            end
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
    Catalog.install(config, bf.installed_path)
  end

  defp cleanup_failed_activation(path, name) do
    Catalog.uninstall(name)
    triage_file(path)
  end

  defp cleanup_failed_activation(path) when is_binary(path) do
    triage_file(path)
  end
  defp cleanup_failed_activation(bf) do
    Catalog.uninstall(bf.name)
    install_dir = build_install_dir(bf)
    File.rm_rf(install_dir)
    triage_file(bf)
  end

  defp triage_file(path) when is_binary(path) do
    triaged_path = build_triaged_path(path)
    File.rm(triaged_path)
    Logger.info("Triaging failed bundle to #{triaged_path}")
    File.rename(path, triaged_path)
  end
  defp triage_file(bf) do
    path = bf.path
    BundleFile.close(bf)
    triage_file(path)
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

  defp build_triaged_path(path) when is_binary(path) do
    triage_root = Application.get_env(:relay, :triage_bundle_root)
    File.mkdir_p(triage_root)
    bundle_file_name = Path.basename(path)
    |> String.replace(~r/.locked$/, "")
    Path.join(triage_root, bundle_file_name)
  end

  defp build_install_dir(bf) do
    {:ok, config} = BundleFile.config(bf)
    bundle = Map.fetch!(config, "bundle")
    name = Map.fetch!(bundle, "name")
    Path.join([Path.dirname(bf.path), name])
  end

  defp installed_foreign_path(bundle_path) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    bundle_file = Path.basename(bundle_path)
    Path.join(bundle_root, bundle_file)
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
