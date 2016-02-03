defmodule Relay.Bundle.Scanner do

  use Adz

  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Installer

  @behaviour :gen_fsm

  defstruct [:pending_path, :pending_bundles, :installers, :first_time]

  def start_link(),
  do: :gen_fsm.start_link({:local, __MODULE__}, __MODULE__, [], [])

  def signal_success(dest) do
    :gen_fsm.send_event(__MODULE__, {:done, dest, self()})
  end

  def signal_failure(path: path) do
    bundle_name = guess_bundle_name(path)
    :gen_fsm.send_event(__MODULE__, {:error, bundle_name, self()})
  end
  def signal_failure(bundle: name) do
    :gen_fsm.send_event(__MODULE__, {:error, name, self()})
  end

  def start_scanning() do
    :gen_fsm.send_event(__MODULE__, :scan)
  end

  def init(_) do
    pending_path = Application.get_env(:relay, :pending_bundle_root)
    :erlang.process_flag(:trap_exit, true)
    report_scan_interval()
    {:ok, :scanning, %__MODULE__{pending_path: pending_path, installers: [],
                                 first_time: true}}
  end

  def scanning(event, state) when event in [:scan, :timeout] do
    {state_name, timeout, state} = case pending_bundle_files() do
                                     [] ->
                                       state = if state.first_time == true do
                                                 Logger.info("All bundles have been deployed.")
                                                 %{state | first_time: false}
                                               else
                                                 state
                                               end
                                       {:scanning, scan_interval(), state}
                                     files ->
                                       {:installing, 0, %{state | first_time: false, pending_bundles: files}}
                                   end
    {:next_state, state_name, state, timeout}
  end

  def installing(:timeout, %__MODULE__{pending_bundles: pending_bundles}=state) do
    installers = Enum.reduce(pending_bundles, %{},
      fn(bundle_file, accum) -> {:ok, pid} = Installer.start_link(bundle_file)
                                Map.put(accum, pid, bundle_file) end)
    {:next_state, :wait_for_installers, %{state | pending_bundles: installers}}
  end

  def wait_for_installers({:done, dest, installer}, %__MODULE__{pending_bundles: installers}=state) do
    case Map.get(installers, installer) do
      nil ->
        {:next_state, :wait_for_installers, state}
      file_name ->
        Logger.info("Bundle file #{file_name} has been successfully deployed to #{dest}")
        installers = Map.delete(installers, installer)
        if Enum.empty?(installers) do
          {:next_state, :scanning, %{state | pending_bundles: []}, scan_interval()}
        else
          {:next_state, :wait_for_installers, %{state | pending_bundles: installers}}
        end
    end
  end
  def wait_for_installers({:error, name, installer}, %__MODULE__{pending_bundles: installers}=state) do
    case Map.get(installers, installer) do
      nil ->
        {:next_state, :wait_for_installers, state}
      _file_name ->
        cleanup_failed_install(name)
        installers = Map.delete(installers, installer)
        if Enum.empty?(installers) do
          {:next_state, :scanning, %{state | pending_bundles: []}, scan_interval()}
        else
          {:next_state, :wait_for_installers, %{state | pending_bundles: installers}}
        end
    end
  end

  def handle_event(_event, state_name, state) do
    {:next_state, state_name, state}
  end

  def handle_sync_event(event, _from, state_name, state) do
    {:reply, {:ignored, event}, state_name, state}
  end

  def code_change(_old, state_name, state, _extra) do
    {:ok, state_name, state}
  end

  def handle_info({:EXIT, sender, reason}, state_name,
                  %__MODULE__{pending_bundles: installers}=state) when state_name in [:installing, :wait_for_installers] do
    case Map.get(installers, sender) do
      nil ->
        {:next_state, :waiting_for_installers, state}
      file_name ->
        Logger.error("Installer for bundle #{file_name} crashed")
        cleanup_failed_install(guess_bundle_name(file_name))
        installers = Map.delete(installers, sender)
        if Enum.empty?(installers) do
          {:next_state, :scanning, %{state | pending_bundles: []}, scan_interval()}
        else
          {:next_state, :waiting_for_installers, %{state | pending_bundles: installers}}
        end
    end
  end
  def handle_info(_event, state_name, state) do
    {:next_state, state_name, state}
  end

  def terminate(_reason, _state_name, _state) do
    :ok
  end

  defp scan_interval() do
    Application.get_env(:relay, :bundle_scan_interval_secs, 30) * 1000
  end

  defp report_scan_interval() do
    interval = :erlang.trunc(scan_interval() / 1000)
    pending_path = Application.get_env(:relay, :pending_bundle_root)
    Logger.info("Scanning for new bundles in #{pending_path} every #{interval} seconds")
  end

  defp pending_bundle_files() do
    pending_path = Application.get_env(:relay, :pending_bundle_root)
    Path.wildcard(Path.join(pending_path, "*#{Spanner.bundle_extension()}")) ++
        Path.wildcard(Path.join(pending_path, "*#{Spanner.skinny_bundle_extension()}"))
  end

  defp guess_bundle_name(path) do
    if String.ends_with?(path, ".cog") do
      Path.rootname(Path.basename(path))
    else
      path
    end
  end

  defp cleanup_failed_install(bundle_name) do
    if String.ends_with?(bundle_name, ".json") or String.ends_with?(bundle_name, ".json.locked") do
      cleanup_failed_skinny_bundle(bundle_name)
    else
      cleanup_failed_bundle(bundle_name)
    end
  end

  defp cleanup_failed_skinny_bundle(file_name) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    [bundle_name|_] = String.split(file_name, ".", parts: 2)
    Catalog.uninstall(Path.basename(bundle_name))
    unless triage_locked_bundle(file_name) do
      triage_bundle(file_name)
    end
    File.rm_rf(Path.join(bundle_root, bundle_name))
  end

  defp cleanup_failed_bundle(bundle_name) do
    bundle_root = Application.get_env(:relay, :bundle)
    Catalog.uninstall(bundle_name)
    unless triage_locked_bundle(bundle_name) do
      triage_bundle(bundle_name)
    end
    File.rm_rf(Path.join(bundle_root, bundle_name))
  end

  defp triage_locked_bundle(bundle_name) do
    pending_root = Application.get_env(:relay, :pending_bundle_root)
    triage_root = Application.get_env(:relay, :triage_bundle_root)
    locked_file = cond do
      String.ends_with?(bundle_name, ".json") ->
        bundle_name <> ".locked"
      String.ends_with?(bundle_name, ".json.locked") ->
        bundle_name
      true ->
        Path.join(pending_root, bundle_name <> ".cog.locked")
    end
    if File.regular?(locked_file) do
      triage_file = make_triage_file(triage_root, bundle_name)
      case File.rename(locked_file, triage_file) do
        :ok ->
          Logger.info("Failed bundle #{bundle_name} triaged to #{triage_file}")
          true
        _error ->
          Logger.error("Error triaging locked bundle #{locked_file} to #{triage_file}")
          case File.rm_rf(locked_file) do
            {:ok, _} ->
              Logger.info("Stubborn locked bundle #{locked_file} has been deleted")
              true
            error ->
              Logger.error("Deleting stubborn locked bundle #{locked_file} failed: #{inspect error}")
              false
          end
      end
    else
      false
    end
  end

  defp triage_bundle(bundle_name) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    triage_root = Application.get_env(:relay, :triage_bundle_root)
    pending_file = cond do
      String.ends_with?(bundle_name, ".json") ->
        Path.join(bundle_root, Path.basename(bundle_name))
      true ->
        Path.join(bundle_root, bundle_name <> ".cog")
    end
    triage_file = make_triage_file(triage_root, bundle_name)
    case File.rename(pending_file, triage_file) do
      :ok ->
        Logger.info("Failed bundle #{bundle_name} triaged to #{triage_file}")
      _error ->
        Logger.error("Error triaging failed bundle #{pending_file} to #{triage_file}")
        case File.rm_rf(pending_file) do
          {:ok, _} ->
            Logger.info("Stubborn failed bundle #{pending_file} has been deleted")
          error ->
            Logger.error("Deleting failed bundle #{pending_file} failed: #{inspect error}")
        end
    end
  end

  defp make_triage_file(triage_root, bundle_name) do
    make_triage_file(triage_root, bundle_name, 0)
  end

  defp make_triage_file(triage_root, bundle_name, n) do
    triage_file = cond do
      String.ends_with?(bundle_name, ".json") ->
        Path.join(triage_root, Path.basename(bundle_name) <> triage_suffix(n))
      String.ends_with?(bundle_name, ".json.locked") ->
        Path.join(triage_root, Path.basename(bundle_name) <> triage_suffix(n))
      true ->
        Path.join(triage_root, bundle_name <> ".cog" <> triage_suffix(n))
    end
    if File.exists?(triage_file) do
      make_triage_file(triage_root, bundle_name, n + 1)
    else
      triage_file
    end
  end

  defp triage_suffix(0), do: ""
  defp triage_suffix(n), do: "." <> Integer.to_string(n)

end
