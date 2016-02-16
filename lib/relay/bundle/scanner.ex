defmodule Relay.Bundle.Scanner do

  use Adz

  alias Relay.Bundle.Installer
  alias Relay.Bundle.Triage

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
    Triage.cleanup_failed_install(name)
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
        Triage.cleanup_failed_install(guess_bundle_name(file_name))
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

  defp queue_next_scan() do
    :timer.apply_after(scan_interval(), __MODULE__, :start_scanning, [])
  end

end
