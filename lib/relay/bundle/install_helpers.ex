defmodule Relay.Bundle.InstallHelpers do

  require Logger

  alias Spanner.Bundle.ConfigValidator
  alias Relay.BundleFile
  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Runner
  alias Relay.Announcer


  def cleanup_failed_activation(path, name) do
    Catalog.uninstall(name)
    triage_file(path)
  end

  def cleanup_failed_activation(path) when is_binary(path) do
    triage_file(path)
  end
  def cleanup_failed_activation(bf) do
    Catalog.uninstall(bf.name)
    install_dir = build_install_dir(bf)
    File.rm_rf(install_dir)
    triage_file(bf)
  end

  def build_install_dir(bf) do
    {:ok, config} = BundleFile.config(bf)
    bundle = Map.fetch!(config, "bundle")
    name = Map.fetch!(bundle, "name")
    Path.join([Path.dirname(bf.path), name])
  end

  def lock_bundle(bundle_path) do
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

  def activate_bundle(path, opts \\ [])
  def activate_bundle(path, opts) when is_binary(path) do
    case BundleFile.open(path) do
      {:ok, bf} ->
        activate_bundle(expand_bundle(bf), opts)
      error ->
        Logger.error("Error opening locked bundle #{path}: #{inspect error}")
        error
    end
  end
  def activate_bundle({:ok, bf}, opts) do
    install_hook = Keyword.get(opts, :install)
    runner = Keyword.get(opts, :runner, &Runner.start_bundle/2)
    case run_install_hook(install_hook, bf) do
      :ok ->
        case register_bundle(bf) do
          :ok ->
            case BundleFile.unlock(bf) do
              {:ok, bf} ->
                case runner.(bf.name, bf.installed_path) do
                  {:ok, _} ->
                    BundleFile.close(bf)
                    {:ok, config} = Catalog.bundle_config(bf.name)
                    case Announcer.announce(config) do
                      :ok ->
                        {:ok, bf.installed_path}
                      error ->
                        Logger.error("Error announcing bundle #{bf.path} to upstream bot: #{inspect error}")
                        cleanup_failed_activation(bf)
                    end
                  error ->
                    Logger.error("Error starting bundle #{bf.path}: #{inspect error}")
                    cleanup_failed_activation(bf)
                end
              error ->
                Logger.error("Error unlocking bundle #{bf.path}: #{inspect error}")
                cleanup_failed_activation(bf)
            end
          _error ->
            cleanup_failed_activation(bf)
        end
      _error ->
        cleanup_failed_activation(bf)
    end
  end
  def activate_bundle({error, bf}, _) do
    BundleFile.close(bf)
    error
  end

  def verify_foreign_executables(installed_path, config) do
    if config["bundle"]["type"] != "foreign" do
      {:ok, config}
    else
      verify_foreign_executables(installed_path, config, config["commands"], [])
    end
  end

  def run_install_script(installed_path, script) do
    {script, rest} = case String.split(script, " ") do
                       [^script] ->
                         {script, []}
                       [script|t] ->
                         {script, t}
                     end
    installed_script = Path.join(installed_path, script)
    cond do
      File.regular?(script) ->
        run_script(Enum.join([script|rest], " "))
      File.regular?(installed_script) ->
        run_script(Enum.join([installed_script|rest], " "))
      true ->
        {:error, {:missing_file, script}}
    end
  end

  # TODO: Need to uninstall whatever executables foreign bundles may bring
  @doc """
  Removes all trace of the given bundle from the system and
  synchronizes state with the bot.
  """
  def deactivate(bundle_name) do
    case bundle_file(bundle_name) do
      {:ok, bundle_file, installed_path} ->
        case lock_bundle(bundle_file) do
          {:ok, locked_path} ->
            :ok = Catalog.uninstall(bundle_name)

            :ok = Runner.stop_bundle(bundle_name)

            # Delete the code
            unless is_nil(installed_path) do
              # Don't do this for skinny bundles
              :ok = remove_bundle_from_code_path(installed_path)
              File.rm_rf(installed_path)
            end

            File.rm_rf(locked_path)

            # Need to tell the bot everything we have now.
            :ok = Announcer.snapshot
          error ->
            Logger.error("Could not lock bundle `#{bundle_name}` for deletion: #{inspect error}")
            error
        end
      {:error, {:not_installed, _}} = error ->
        Logger.error("The bundle `#{bundle_name}` is not installed")
        error
      {:error, {:no_bundle_file, _}} = error ->
        Logger.error("The bundle file for `#{bundle_name}` was not found")
        error
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
            {:error, {:no_bundle_file, bundle_name}}
          end
        end
    end
  end

  # Ideally, this might take place in a shutdown hook somewhere
  defp remove_bundle_from_code_path(installed_path) do
    _ = Code.delete_path(Path.join(installed_path, "ebin"))
    :ok
  end

  defp run_script(script) do
    File.chmod(script, 0o755)
    result = Porcelain.shell(script, err: :out)
    if result.status == 0 do
      Logger.info("Install script #{script} completed: " <> result.out)
      :ok
    else
      Logger.error("Install script #{script} exited with status #{result.status}: " <> result.out)
      {:error, :install_hook_failed}
    end
  end

  defp verify_foreign_executables(_installed_path, config, [], commands) do
    commands = Enum.reverse(commands)
    {:ok, Map.put(config, "commands", commands)}
  end
  defp verify_foreign_executables(installed_path, config, [cmd|t], accum) do
    executable = cmd["executable"]
    if File.regular?(executable) do
      verify_foreign_executables(installed_path, config, t, [cmd|accum])
    else
      if File.dir?(installed_path) do
        private_executable = Path.join(installed_path, executable)
        if File.regular?(private_executable) do
          File.chmod(private_executable, 0o755)
          cmd = Map.put(cmd, "executable", private_executable)
          verify_foreign_executables(installed_path, config, t, [cmd|accum])
        else
          {:error, {cmd["name"], :missing_file, [executable, private_executable]}}
        end
      else
        {:error, {cmd["name"], :missing_file, [executable]}}
      end
    end
  end

  defp expand_bundle(bf) do
    install_dir = build_install_dir(bf)
    case File.exists?(install_dir) do
      # Bail here because we're already installed
      true ->
        {:ok, bf}
      false ->
        bundle_root = Application.get_env(:relay, :bundle_root)
        case BundleFile.expand_into(bf, bundle_root) do
          {:ok, bf} ->
            case File.dir?(install_dir) do
              true ->
                case BundleFile.verify_installed_files(bf) do
                  :ok ->
                    {:ok, bf}
                  {:failed, files} ->
                    files = Enum.join(files, "\n")
                    Logger.error("Bundle #{bf.path} contains corrupted files:\n#{files}")
                    {{:error, :corrupted_bundle}, bf}
                end
              _ ->
                Logger.error("Bundle #{bf.path} did not expand into expected install directory #{install_dir}")
                {{:error, :failed_expansion}, bf}
            end
          error ->
            {error, bf}
        end
    end
  end

  defp register_bundle(bf) do
    {:ok, config} = BundleFile.config(bf)
    case ConfigValidator.validate(config) do
      :ok ->
        case verify_foreign_executables(bf.installed_path, config) do
          {:ok, config} ->
            Catalog.install(config, bf.installed_path)
          {error, {command, :missing_files, alts}} ->
            Logger.error("Error finding executables for #{command} in foreign bundle #{bf.path}: #{Enum.join(alts, ",")}")
            error
        end
      {:error, {error_type, _, message}}=error ->
        Logger.error("config.json for bundle #{bf.path} failed validation: #{error_type}  #{message}")
        error
    end
  end

  defp run_install_hook(nil, _) do
    :ok
  end
  defp run_install_hook(hook, bf) do
    try do
      hook.(bf)
    rescue
      e ->
        Logger.error("Error running install hook for bundle #{bf.installed_path}: #{inspect e}")
        for line <- System.stacktrace() do
          Logger.error(inspect(line))
        end
        {:error, :install_hook_failed}
    end
  end

  defp triage_file(path) when is_binary(path) do
    triaged_path = build_triaged_path(path)
    File.rm(triaged_path)
    Logger.info("Triaging failed bundle to #{triaged_path}")
    File.rename(path, triaged_path)
  end
  defp triage_file(bf) do
    path = bf.path
    BundleFile.close(bf)
    triage_file(path)
  end

  defp build_triaged_path(path) when is_binary(path) do
    triage_root = Application.get_env(:relay, :triage_bundle_root)
    File.mkdir_p(triage_root)
    bundle_file_name = Path.basename(path)
    |> String.replace(~r/.locked$/, "")
    Path.join(triage_root, bundle_file_name)
  end

end
