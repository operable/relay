defmodule Relay.Bundle.Scanner do

  use Adz

  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Installer

  @behaviour :gen_fsm

  defstruct [:pending_path, :pending_bundles, :installers]

  def start_link(),
  do: :gen_fsm.start_link({:local, __MODULE__}, __MODULE__, [], [])

  def signal_success(dest) do
    :gen_fsm.send_all_state_event(__MODULE__, {:done, dest, self()})
  end

  def signal_failure(path: path) do
    bundle_name = guess_bundle_name(path)
    :gen_fsm.send_all_state_event(__MODULE__, {:error, bundle_name, self()})
  end
  def signal_failure(bundle: name) do
    :gen_fsm.send_all_state_event(__MODULE__, {:error, name, self()})
  end

  def start_scanning() do
    :gen_fsm.send_event(__MODULE__, :scan)
  end

  def init(_) do
    pending_path = Application.get_env(:relay, :pending_bundle_root)
    File.mkdir_p!(pending_path)
    :erlang.process_flag(:trap_exit, true)
    report_scan_interval()
    queue_next_scan()
    {:ok, :scanning, %__MODULE__{pending_path: pending_path, installers: %{}}}
  end

  def scanning(:scan, state) do
    case pending_bundle_files() do
      [] ->
        queue_next_scan()
        {:next_state, :scanning, state}
      files ->
        {:next_state, :installing, %{state | pending_bundles: files}, 0}
    end
  end

  def installing(:timeout, %__MODULE__{pending_bundles: pending_bundles}=state) do
    installers = Enum.reduce(pending_bundles, %{},
      fn(bundle_file, accum) -> {:ok, pid} = Installer.start(bundle_file)
                                :erlang.monitor(:process, pid)
                                Installer.install_bundle(pid)
                                Map.put(accum, pid, bundle_file) end)
    {:next_state, :wait_for_installers, %{state | installers: installers, pending_bundles: []}}
  end

  def handle_event({:done, _dest, installer}, state_name, %__MODULE__{installers: installers}=state) do
    installers = Map.delete(installers, installer)
    next_state(state_name, %{state | installers: installers})
  end
  def handle_event({:error, name, installer}, state_name, %__MODULE__{installers: installers}=state) do
    cleanup_failed_install(name)
    installers = Map.delete(installers, installer)
    next_state(state_name, %{state | installers: installers})
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

  def handle_info({:DOWN, _mref, :process, sender, reason}, state_name,
                  %__MODULE__{installers: installers}=state) do
    case Map.get(installers, sender) do
      nil ->
        next_state(state_name, state)
      file_name ->
        Logger.info("Installer for bundle #{file_name} crashed: #{inspect reason}")
        cleanup_failed_install(guess_bundle_name(file_name))
        installers = Map.delete(installers, sender)
        next_state(state_name, %{state | installers: installers})
    end
  end

  def handle_info(:current_state, state_name, state) do
    Logger.debug("#{state_name}")
    {:next_state, state_name, state}
  end
  def handle_info(_event, state_name, state) do
    {:next_state, state_name, state}
  end

  def terminate(_reason, _state_name, _state) do
    :ok
  end

  defp next_state(:wait_for_installers, %__MODULE__{installers: %{}}=state) do
    queue_next_scan()
    {:next_state, :scanning, state}
  end
  defp next_state(:wait_for_installers, state) do
    {:next_state, :wait_for_installers, state}
  end
  defp next_state(current_state, state) do
    {:next_state, current_state, state}
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
    [bundle_name|_] = String.split(file_name, ".", parts: 2)
    Catalog.uninstall(Path.basename(bundle_name))
    triage_bundle(file_name)
  end

  defp cleanup_failed_bundle(bundle_name) do
    Logger.debug("Cleaning up #{inspect bundle_name} bundle")
    bundle_root = Application.get_env(:relay, :bundle_root)
    Catalog.uninstall(bundle_name)
    triage_bundle(bundle_name)
    File.rm_rf(Path.join(bundle_root, bundle_name))
  end

  defp triage_bundle(bundle) do
    pending_root = Application.get_env(:relay, :pending_bundle_root)
    bundle_root = Application.get_env(:relay, :bundle_root)
    triage_root = Application.get_env(:relay, :triage_bundle_root)

    ensure_triage_root()
    triage_file = make_triage_file(triage_root, bundle)

    if File.exists?(bundle) do
      triage_bundle(bundle, triage_file)
    else
      pending_file = build_bundle_path(pending_root, bundle)
      installed_file = build_bundle_path(bundle_root, bundle)
      locked_file = pending_file <> ".locked"
      cond do
        File.exists?(locked_file) ->
          triage_bundle(locked_file, triage_file)
        File.exists?(pending_file) ->
          triage_bundle(pending_file, triage_file)
        File.exists?(installed_file) ->
          triage_bundle(pending_file, triage_file)
        true ->
          true
      end
    end
  end

  defp triage_bundle(source, dest) do
    ensure_triage_root()
    case File.rename(source, dest) do
      :ok ->
        Logger.info("Failed bundle #{source} triaged to #{dest}")
        true
      _error ->
        Logger.error("Error triaging failed bundle #{source} to #{dest}")
        case File.rm_rf(source) do
          {:ok, _} ->
            Logger.info("Stubborn failed bundle #{source} has been deleted")
            true
          error ->
            Logger.error("Deleting failed bundle #{source} failed: #{inspect error}")
            false
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

  defp build_bundle_path(root_dir, bundle) do
    bundle = Path.basename(bundle)
    if String.ends_with?(bundle, ".json") or String.ends_with?(bundle, ".cog") do
      Path.join(root_dir, bundle)
    else
      Path.join(root_dir, bundle <> ".cog")
    end
  end

  defp triage_suffix(0), do: ""
  defp triage_suffix(n), do: "." <> Integer.to_string(n)

  defp queue_next_scan() do
    :timer.apply_after(scan_interval(), __MODULE__, :start_scanning, [])
  end

  defp ensure_triage_root() do
    triage_root = Application.get_env(:relay, :triage_bundle_root)
    File.mkdir_p(triage_root)
  end

end
