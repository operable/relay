defmodule Relay.Bundle.InstallHelpers do

  require Logger

  alias Relay.BundleFile
  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Runner
  alias Relay.Announcer

  # TODO: Need to uninstall whatever executables foreign bundles may bring
  @doc """
  Removes all trace of the given bundle from the system and
  synchronizes state with the bot.
  """
  def deactivate(bundle_name) do
    Logger.info("Initiating deactivation of bundle `#{bundle_name}`")
    deactivate(bundle_name, bundle_file(bundle_name))
  end

  def run_script(bundle_file, script, kind \\ "Install")
  def run_script(%BundleFile{}=bf, script, kind) do
    run_script(bf.installed_path, script, kind)
  end
  def run_script(installed_path, script, kind) when is_binary(installed_path) do
    install_dir = if String.ends_with?(installed_path, ".json") or String.ends_with?(installed_path, ".json.locked") do
      Path.dirname(installed_path)
    else
      installed_path
    end
    {script, rest} = case String.split(script, " ") do
                       [^script] ->
                         {script, []}
                       [script|t] ->
                         {script, t}
                     end
    installed_script = Path.join(install_dir, script)
    cond do
      File.regular?(script) ->
        exec_script(install_dir, Enum.join([script|rest], " "), kind)
      File.regular?(installed_script) ->
        File.chmod(installed_script, 0o755)
        exec_script(install_dir, Enum.join([installed_script|rest], " "), kind)
      true ->
        Logger.error("#{kind} script #{script} not found for installed bundle #{installed_path}")
        :error
    end
  end


  defp exec_script(working_dir, script, kind) do
    result = Porcelain.shell(script, err: :out, dir: working_dir)
    if result.status == 0 do
      Logger.info("#{kind} script #{script} completed: " <> result.out)
      :ok
    else
      Logger.error("#{kind} script #{script} exited with status #{result.status}: " <> result.out)
      :error
    end
  end


  defp deactivate(bundle_name, {:ok, nil, installed_path}) do
    :ok = Runner.stop_bundle(bundle_name)
    run_uninstall_hook(bundle_name)
    :ok = Catalog.uninstall(bundle_name)
    remove_installed_path(bundle_name, installed_path)
    :ok = Announcer.snapshot
    Logger.info("Bundle `#{bundle_name}` successfully deactivated")
  end
  defp deactivate(bundle_name, {:ok, bundle_file, installed_path}) do
    case lock_bundle(bundle_file) do
      {:ok, locked_path} ->
        :ok = Runner.stop_bundle(bundle_name)
        run_uninstall_hook(bundle_name)
        :ok = Catalog.uninstall(bundle_name)
        remove_installed_path(bundle_name, installed_path)
        case File.rm_rf(locked_path) do
          {:ok, [^locked_path]} ->
            Logger.info("Deleted bundle file for `#{bundle_name}`")
          error ->
            Logger.error("Error deleting `#{locked_path}`: #{inspect error}")
        end

        # Need to tell the bot everything we have now.
        :ok = Announcer.snapshot
        Logger.info("Bundle `#{bundle_name}` successfully deactivated")
      error ->
        Logger.error("Could not lock bundle `#{bundle_name}` for deletion: #{inspect error}")
        error
    end
  end
  defp deactivate(bundle_name, {:error, {:not_installed, _}}=error) do
    Logger.error("The bundle `#{bundle_name}` is not installed")
    error
  end
  defp deactivate(bundle_name, {:error, {:no_bundle_file, _}}=error) do
    Logger.error("The bundle file for `#{bundle_name}` was not found")
    error
  end

  defp run_uninstall_hook(bundle_name) do
    if Catalog.installed?(bundle_name) do
      {:ok, config} = Catalog.bundle_config(bundle_name)
      bundle = config["bundle"]
      if Map.has_key?(bundle, "uninstall") do
        installed_path = Catalog.installed_path(bundle_name)
        run_script(installed_path, bundle["uninstall"], "Uninstall")
      else
        :ok
      end
    else
      :ok
    end
  end

  defp remove_installed_path(_bundle_name, nil) do
    :ok
  end
  defp remove_installed_path(bundle_name, installed_path) do
      # Try 'rm' first since the directory could be symlinked by someone writing
      # a command. Traversing the link and deleting their code would make them
      # grumpy.
      case File.rm(installed_path) do
        :ok ->
          Logger.info("Deleted `#{installed_path}` for bundle `#{bundle_name}`")
          :ok
        {:error, _} ->
          case File.rm_rf(installed_path) do
            {:ok, []} ->
              Logger.warn("Could not find `#{installed_path}` to delete!")
            {:ok, _files} ->
              Logger.info("Deleted `#{installed_path}` for bundle `#{bundle_name}`")
        error ->
          Logger.error("Error deleting `#{installed_path}`: #{inspect error}")
      end
    end
  end

  # Return the path to the bundle file (i.e., the zip file), as well
  # as the installed bundle directory.
  #
  # Returns an error tuple if no such bundle is installed, or the zip
  # file cannot be found.
  #
  # The "installed path" will be nil for skinny bundles.
  defp bundle_file(bundle_name) do
    case Catalog.installed_path(bundle_name) do
      nil ->
        {:error, {:not_installed, bundle_name}}
      installed_path ->
        if String.ends_with?(installed_path, Spanner.skinny_bundle_extension) do
          {:ok, installed_path, nil}
        else
          installed_bundle_file = installed_path <> Spanner.bundle_extension
          if File.exists?(installed_bundle_file) do
            {:ok, installed_bundle_file, installed_path}
          else
            if File.dir?(installed_path) do
              {:ok, nil, installed_path}
            else
              {:error, {:no_bundle_file, bundle_name}}
            end
          end
        end
    end
  end

  defp lock_bundle(bundle_path) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    locked_file = Path.basename(bundle_path) <> ".locked"
    locked_path = Path.join(bundle_root, locked_file)
    if File.regular?(locked_path) == true do
      Logger.error("Error locking bundle #{bundle_path}: Locked bundle #{locked_path} already exists")
      {:error, :locked_bundle_exists}
    else
      case File.rename(bundle_path, locked_path) do
        :ok ->
          {:ok, locked_path}
        error ->
          Logger.error("Error locking bundle #{bundle_path}: #{inspect error}")
          error
      end
    end
  end

end
