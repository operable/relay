defmodule Relay.Bundle.ForeignSkinnyInstaller do

  @behaviour Relay.Bundle.Installer

  require Logger

  alias Spanner.Bundle.ConfigValidator
  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Runner
  alias Relay.Bundle.InstallHelpers, as: Helpers
  alias Relay.Announcer

  def install(bundle_path) do
    parse_contents(bundle_path, File.read(bundle_path))
  end

  defp parse_contents(bundle_path, {:ok, contents}) do
    validate_config(bundle_path, Poison.decode(contents))
  end
  defp parse_contents(bundle_path, error) do
    Logger.error("Error reading bundle #{bundle_path}: #{inspect error}")
    Helpers.cleanup_failed_activation(bundle_path)
  end

  defp validate_config(bundle_path, {:ok, config}) do
    install_file(bundle_path, config, ConfigValidator.validate(config))
  end
  defp validate_config(bundle_path, error) do
    Logger.error("Error parsing config.json for bundle #{bundle_path}: #{inspect error}")
    Helpers.cleanup_failed_activation(bundle_path)
  end

  defp install_file(bundle_path, config, :ok) do
    installed_path = installed_foreign_path(bundle_path)
    verify_executables(bundle_path, installed_path, config, File.rename(bundle_path, installed_path))
  end
  defp install_file(bundle_path, _config, error) do
    Logger.error("Error validating bundle config for bundle #{bundle_path}: #{inspect error}")
    Helpers.cleanup_failed_activation(bundle_path)
  end

  defp verify_executables(bundle_path, installed_path, config, :ok) do
    execute_install_hook(bundle_path, installed_path, config["bundle"]["name"],
                         Helpers.verify_foreign_executables(installed_path, config))
  end
  defp verify_executables(bundle_path, installed_path, config, error) do
    Logger.error("Error installing bundle #{bundle_path} to #{installed_path}: #{inspect error}")
    Helpers.cleanup_failed_activation(installed_path, config["bundle"]["name"])
  end

  defp execute_install_hook(bundle_path, installed_path, _bundle_name, {:ok, config}) do
    bundle = config["bundle"]
    case Map.get(bundle, "install") do
      nil ->
        add_to_catalog(bundle_path, config, :ok)
      script ->
        add_to_catalog(bundle_path, config, Helpers.run_install_script(installed_path, script))
    end
  end
  defp execute_install_hook(bundle_path, installed_path, bundle_name, {:error, {cmd, :missing_file, files}}) do
    Logger.error("Foreign bundle #{bundle_path} missing files for #{cmd}: #{Enum.join(files, ",")}")
    Helpers.cleanup_failed_activation(installed_path, bundle_name)
  end

  defp add_to_catalog(bundle_path, config, :ok) do
    installed_path = installed_foreign_path(bundle_path)
    bundle_name = config["bundle"]["name"]
    start_bundle(bundle_path, config, installed_path, bundle_name, Catalog.install(config, installed_path))
  end
  defp add_to_catalog(bundle_path, config, {:error, :install_hook_failed}) do
    installed_path = installed_foreign_path(bundle_path)
    Helpers.cleanup_failed_activation(installed_path, config["bundle"]["name"])
  end
  defp add_to_catalog(bundle_path, config, {:error, {:missing_file, script}}) do
    Logger.error("Install script #{script} is missing for bundle #{bundle_path}")
    installed_path = installed_foreign_path(bundle_path)
    Helpers.cleanup_failed_activation(installed_path, config["bundle"]["name"])
  end


  defp start_bundle(bundle_path, config, installed_path, bundle_name, :ok) do
    announce_bundle(bundle_path, config, bundle_name, Runner.start_foreign_bundle(bundle_name, installed_path))
  end
  defp start_bundle(bundle_path, _config, installed_path, bundle_name, error) do
    Logger.error("Error adding bundle #{bundle_path} to bundle catalog: #{inspect error}")
    Helpers.cleanup_failed_activation(installed_path, bundle_name)
  end

  defp announce_bundle(bundle_path, config, bundle_name, {:ok, _}) do
    finish_install(bundle_path, bundle_name, Announcer.announce(config))
  end
  defp announce_bundle(bundle_path, _config, bundle_name, error) do
    Logger.error("Error starting bundle #{bundle_path}: #{inspect error}")
    installed_path = installed_foreign_path(bundle_path)
    Helpers.cleanup_failed_activation(installed_path, bundle_name)
  end

  defp finish_install(bundle_path, _bundle_name, :ok) do
    installed_path = installed_foreign_path(bundle_path)
    Logger.info("Bundle #{bundle_path} was installed to #{installed_path} successfully.")
  end
  defp finish_install(bundle_path, bundle_name, error) do
    Logger.error("Error announcing bundle #{bundle_path}: #{inspect error}")
    installed_path = installed_foreign_path(bundle_path)
    Helpers.cleanup_failed_activation(installed_path, bundle_name)
  end

  defp installed_foreign_path(bundle_path) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    bundle_file = Path.basename(bundle_path)
    Path.join(bundle_root, bundle_file)
  end

end
