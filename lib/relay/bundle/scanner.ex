defmodule Relay.Bundle.Scanner do

  use GenServer
  use Relay.Logging

  defstruct [:upload_path, :timer]

  @bundle_suffix ".loop"

  def start_link(),
  do: GenServer.start_link(__MODULE__, name: __MODULE__)

  def init(_) do
    upload_path = Application.get_env(:relay, :bundle_upload_root)
    case File.exists?(upload_path) do
      false ->
        prepare_for_uploads(upload_path)
      true ->
        scan_for_uploads(upload_path)
    end
  end

  def handle_info(:scan, state) do
    install_bundles(pending_bundle_files())
    {:ok, timer} = :timer.send_after((scan_interval() * 1000), :scan)
    {:noreply, %{state | timer: timer}}
  end
  def handle_info(_, state) do
    {:noreply, state}
  end

  defp prepare_for_uploads(upload_path) do
    File.mkdir_p!(upload_path)
    ready(finish_init(%__MODULE__{upload_path: upload_path}))
  end

  defp scan_for_uploads(upload_path) do
    case File.dir?(upload_path) do
      false ->
        Logger.error("Error starting bundle scanner: Upload path #{upload_path} is not a directory")
        {:error, :bad_upload_path}
      true ->
        case pending_bundle_files() do
          [] ->
            Logger.info("No bundle uploads pending")
            ready(finish_init(%__MODULE__{upload_path: upload_path}))
          bundles ->
            if length(bundles) == 1 do
              Logger.info("Found #{length(bundles)} pending bundle upload. Installation will begin in 10 seconds.")
            else
              Logger.info("Found #{length(bundles)} pending bundle uploads. Installation will begin in 10 seconds.")
            end
            ready(finish_init(10, %__MODULE__{upload_path: upload_path}))
        end
    end
  end

  defp finish_init(state) do
    finish_init(scan_interval(), state)
  end

  defp finish_init(wait, state) do
    {:ok, timer} = :timer.send_after((wait * 1000), :scan)
    {:ok, %{state | timer: timer}}
  end

  defp scan_interval() do
    Application.get_env(:relay, :bundle_scan_interval_secs)
  end

  defp pending_bundle_files() do
    upload_path = Application.get_env(:relay, :bundle_upload_root)
    Path.wildcard(Path.join(upload_path, "*#{@bundle_suffix}"))
  end

  defp install_bundles([]) do
    :ok
  end
  defp install_bundles([bundle_path|t]) do
    install_bundle(bundle_path)
    install_bundles(t)
  end

  defp install_bundle(_bundle_path) do
    :ok
  end

  # defp lock_bundle(bundle_path) do
  #   bundle_root = Application.get_env(:relay, :bundle_root)
  #   locked_file = Path.basename(bundle_path) <> ".locked"
  #   locked_path = Path.join(bundle_root, bundle_file)
  #   case File.rename(bundle_path, locked_path) do
  #     :ok ->
  #       {:ok, locked_path}
  #     error ->
  #       Logger.error("Error locking uploaded bundle #{bundle_path}: #{inspect error}")
  #       error
  #   end
  # end

end
