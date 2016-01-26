defmodule Relay.Bundle.ElixirInstaller do

  @behaviour Relay.Bundle.Installer

  require Logger

  alias Relay.Bundle.InstallHelpers, as: Helpers

  def install(bundle_path) do
    Logger.info("Installing Elixir bundle #{bundle_path}.")
    case Helpers.lock_bundle(bundle_path) do
      {:ok, locked_path} ->
        case Helpers.activate_bundle(locked_path) do
          {:ok, installed_path} ->
            Logger.info("Elixir Bundle #{bundle_path} installed to #{installed_path} successfully.")
          _error ->
            Logger.info("Installation of Elixir bundle #{bundle_path} failed.")
        end
      error ->
        error
    end
  end

end
