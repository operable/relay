defmodule Relay do

  use Application
  require Logger

  alias Relay.Util.FileFinder

  def start(_, _) do
    goon_check()
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

end
