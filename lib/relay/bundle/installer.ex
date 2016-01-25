defmodule Relay.Bundle.Installer do

  @type bundle_path :: String.t

  @callback install(bundle_path) :: :ok | {:error, term}

end
