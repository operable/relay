defmodule Relay do

  use Application
  require Logger

  def start(_, _) do
    case Relay.TopSupervisor.start_link() do
      {:ok, pid} ->
        {:ok, pid}
      error ->
        Logger.error("Error starting relay: #{inspect error}")
        error
    end
  end

end
