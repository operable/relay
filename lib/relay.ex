defmodule Relay do

  use Application

  def start(_, _) do
    Relay.TopSupervisor.start_link
  end

end
