defmodule Relay do

  use Application
  require Logger

  alias Relay.Util.FileFinder

  def start(_, _) do
    goon_check()
    sanity_check()
    case Relay.TopSupervisor.start_link() do
      {:ok, pid} ->
        {:ok, pid}
      error ->
        Logger.error("Error starting relay: #{inspect error}")
        error
    end
  end

  defp goon_check() do
    f = FileFinder.make(env_var: "$PATH")
    case FileFinder.find(f, "goon", [:executable]) do
      nil ->
        Logger.warn("Failed to detect 'goon' executable via $PATH. Command execution may be unstable.")
        Logger.info("""
goon is available from the following sources:
  Operable's homebrew repo: https://github.com/operable/homebrew-operable
  Alexei Sholik's GitHub repo: https://github.com/alco/goon
""")
      path ->
        Logger.info("'goon' executable found: #{path}.")
    end
  end

  defp sanity_check() do
    {smp_status, smp_message} = verify_smp()
    {ds_status, ds_message} = verify_dirty_schedulers()
    if smp_status == :ok do
      Logger.info(smp_message)
    else
      Logger.error(smp_message)
    end
    if ds_status == :ok do
      Logger.info(ds_message)
    else
      Logger.error(ds_message)
    end
    unless smp_status == :ok and ds_status == :ok do
      Logger.error("Application start aborted.")
      Logger.flush()
      :init.stop()
    end
  end

  defp verify_smp() do
    if :erlang.system_info(:schedulers_online) < 2 do
      {:error, "SMP support disabled. Add '-smp enable' to $ERL_FLAGS and restart Relay."}
    else
      {:ok, "SMP support enabled."}
    end
  end

  defp verify_dirty_schedulers() do
    try do
      :erlang.system_info(:dirty_cpu_schedulers)
      {:ok, "Dirty CPU schedulers enabled."}
    rescue
      ArgumentError ->
        {:error, """
Erlang VM is missing support for dirty CPU schedulers.
See http://erlang.org/doc/installation_guide/INSTALL.html for information on enabling dirty scheduler support.
"""}
    end
  end

end
