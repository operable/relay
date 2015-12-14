defmodule Relay do

  use Application

  def start(_, _) do
    case Relay.TopSupervisor.start_link() do
      {:ok, pid} ->
        Relay.Bundle.Scanner.start_scanning
        {:ok, pid}
      error ->
        error
    end
  end

end
