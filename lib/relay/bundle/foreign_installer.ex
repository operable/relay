defmodule Relay.Bundle.ForeignInstaller do

  @behavour Relay.Bundle.Installer

  require Logger

  alias Relay.Bundle.Runner
  alias Relay.Bundle.InstallHelpers, as: Helpers

  def install(bundle_path) do
    Logger.info("Installing foreign bundle #{bundle_path}.")
    case Helpers.lock_bundle(bundle_path) do
      {:ok, locked_path} ->
        case Helpers.activate_bundle(locked_path, preinstall: &exec_preinstall/1,
            runner: &Runner.start_foreign_bundle/2) do
          {:ok, installed_path} ->
            Logger.info("Foreign Bundle #{bundle_path} installed to #{installed_path} successfully.")
          _error ->
            Logger.info("Installation of foreign bundle #{bundle_path} failed.")
        end
      error ->
        error
    end
  end

  def exec_preinstall(_bf) do
    :ok
  end

end
