defmodule Relay.Bundle.Installer do

  use GenServer
  require Logger
  alias Relay.Announcer
  alias Relay.BundleFile
  alias Relay.Bundle.Scanner
  alias Relay.Bundle.Catalog
  alias Relay.Bundle.Runner
  alias Spanner.Bundle.ConfigValidator

  defstruct [:bundle_path]

  def start(bundle_path) do
    GenServer.start(__MODULE__, [bundle_path])
  end

  def install_bundle(installer) do
    GenServer.call(installer, :install_bundle, 50)
  end

  def init([bundle_path]) do
    :random.seed(:erlang.timestamp())
    {:ok, %__MODULE__{bundle_path: bundle_path}}
  end

  def handle_call(:install_bundle, _from, state) do
    {:reply, :ok, state, :random.uniform(50) + 10}
  end
  def handle_info(:timeout, %__MODULE__{bundle_path: bundle_path}=state) do
    case lock_bundle(bundle_path) do
      :stop ->
        {:stop, :normal, state}
      {:ok, locked_path} ->
        {result, bundle_file} = try_install(locked_path)
        if result == :error do
          reset_lock(bundle_path, locked_path)
          if BundleFile.bundle_file?(bundle_file) do
            {:ok, config} = BundleFile.config(bundle_file)
            Scanner.signal_failure(bundle: config["bundle"]["name"])
          else
            Scanner.signal_failure(path: bundle_path)
          end
        else
          File.rm_rf(locked_path)
          if BundleFile.bundle_file?(bundle_file) do
            Scanner.signal_success(bundle_file.installed_path)
          else
            Scanner.signal_success(bundle_path)
          end
        end
        {:stop, :normal, state}
    end
  end

  defp reset_lock(bundle_path, locked_path) do
    if File.exists?(locked_path) do
      unless File.exists?(bundle_path) do
        File.rename(locked_path, bundle_path)
      end
    end
  end

  defp try_install(bundle_path) do
    if String.ends_with?(bundle_path, ".json.locked") do
      try_simple_install(bundle_path)
    else
      try_full_install(bundle_path)
    end
  end

  defp try_simple_install(bundle_path) do
    case File.read(bundle_path) do
      {:ok, contents} ->
        case Poison.decode(contents) do
          {:ok, config} ->
            activate_bundle(bundle_path, config)
          error ->
            Logger.error("Error parsing JSON bundle config #{bundle_path}: #{inspect error}")
            {:error, bundle_path}
        end
      error ->
        Logger.error("Error reading bundle config #{bundle_path}: #{inspect error}")
        {:error, bundle_path}
    end
  end

  defp try_full_install(bundle_path) do
    case BundleFile.open(bundle_path) do
      {:ok, bf} ->
        case BundleFile.config(bf) do
          {:ok, config} ->
            activate_bundle(bf, config)
          _ ->
            Logger.error("Unable to open config.json for bundle #{bf.path}. Corrupted archive or bad JSON?")
            BundleFile.close(bf)
            {:error, nil}
        end
      error ->
        Logger.error("Error opening bundle file #{bundle_path}: #{inspect error}")
        {:error, nil}
    end
  end

  defp activate_bundle(bf, config) do
    case ConfigValidator.validate(config) do
      :ok ->
        case verify_template_paths(bf, config) do
          {:ok, config} ->
            case verify_executables(bf, config) do
              {:ok, config} ->
                verify_install_hook(bf, config)
              {:error, {:missing_file, command, file}} ->
                Logger.error("Failed to find executable #{file} for command #{command}")
                {:error, bf}
            end
          {:error, {:missing_file, command, file}} ->
            Logger.error("Failed to find template file #{file} for command #{command}")
            {:error, bf}
          {:error, {:unable_to_open, command, file}} ->
            Logger.error("Unable to open the template file #{file} for command #{command}")
            {:error, bf}
          {:error, {:unexpected_value, value}} ->
            Logger.error("Illegal template value: #{inspect value}")
            {:error, bf}
        end
      {:error, {error_type, _, message}} ->
        if BundleFile.bundle_file?(bf) do
          Logger.error("config.json for bundle #{bf.path} failed validation: #{error_type} #{message}")
        else
          Logger.error("config.json for bundle #{bf} failed validation: #{error_type} #{message}")
        end
        {:error, bf}
    end
  end

  defp verify_template_paths(bf, config) when is_binary(bf) do
    templates = config["templates"]
    case verify_simple_templates(templates) do
      :ok ->
        {:ok, config}
      error ->
        error
    end
  end
  defp verify_template_paths(bf, config) do
    templates = config["templates"]
    case verify_normal_templates(templates, bf, []) do
      {:ok, templates} ->
        {:ok, %{config | "templates" => templates}}
      error ->
        error
    end
  end

  defp verify_normal_templates([], _bf, templates) do
    {:ok, Enum.reverse(templates)}
  end
  defp verify_normal_templates([template|t], bf, templates) do
    case verify_template(bf, template) do
      {:ok, template} ->
        verify_normal_templates(t, bf, [template|templates])
      error ->
        error
    end
  end

  defp verify_simple_templates([]) do
    :ok
  end
  defp verify_simple_templates([template|t]) when is_map(template) do
    case verify_template(nil, template) do
      {:ok, _} ->
        verify_simple_templates(t)
      error ->
        error
    end
  end

  defp verify_template(nil, %{"path" => path}=template) do
    case check_bundle_file(path) do
      :ok ->
        {:ok, template}
      error ->
        error
    end
  end
  defp verify_template(bf, %{"path" => path}) do
    full_path = Path.join(bf.installed_path, path)
    case check_bundle_file(full_path) do
      :ok ->
        {:ok, %{"path" => full_path}}
      error ->
        error
    end
  end
  defp verify_template(_, %{"template" => contents}=template) when is_binary(contents) do
    {:ok, template}
  end
  defp verify_template(_, template) do
    {:error, {:unexpected_value, template}}
  end

  defp verify_install_hook(bf, config) when is_binary(bf) do
    bundle = config["bundle"]
    case Map.get(bundle, "install") do
      nil ->
        expand_bundle(bf, config)
      script ->
        {script, _} = case String.split(script, " ") do
                        [^script] ->
                          {script, []}
                        [script|t] ->
                          {script, t}
                      end
        if File.regular?(script) do
          case run_install_hook(bf, config) do
            :ok ->
              expand_bundle(bf, config)
            error ->
              Logger.error("Error executing install script for bundle #{bf}: #{inspect error}")
              {:error, nil}
          end
        else
          Logger.error("Install script #{script} for bundle #{bf} not found")
          {:error, nil}
        end
    end
  end
  defp verify_install_hook(bf, config) do
    bundle = config["bundle"]
    case Map.get(bundle, "install") do
      nil ->
        expand_bundle(bf, config)
      script ->
        {script, _} = case String.split(script, " ") do
                        [^script] ->
                          {script, []}
                        [script|t] ->
                          {script, t}
                      end
        if File.regular?(script) or BundleFile.find_file(bf, script) != nil do
          expand_bundle(bf, config)
        else
          Logger.error("Install script #{script} for bundle #{bf.path} not found")
          {:error, bf}
        end
    end
  end

  defp expand_bundle(bf, config) when is_binary(bf) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    install_path = build_install_dest(bundle_root, config, true)
    case File.rename(bf, install_path) do
      :ok ->
        register_and_start_bundle(install_path, config)
      error ->
        Logger.error("Error installing simple bundle #{bf} to #{install_path}: #{inspect error}")
        {:error, bf}
    end
  end
  defp expand_bundle(bf, config) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    install_dir = build_install_dest(bundle_root, config)
    if File.exists?(install_dir) do
      File.rm_rf(install_dir)
    end
    case BundleFile.expand_into(bf, bundle_root) do
      {:ok, bf} ->
        case File.dir?(install_dir) do
          true ->
            case BundleFile.verify_installed_files(bf) do
              :ok ->
                case run_install_hook(bf, config) do
                  :ok ->
                    case set_permssions_for_executables(install_dir, config) do
                      :ok ->
                        register_and_start_bundle(bf, config)
                      error ->
                        Logger.error("Error setting executable permissions for bundle #{bf.path}: #{inspect error}")
                        {:error, bf}
                    end
                  :error ->
                    {:error, bf}
                end
              {:failed, files} ->
                files = Enum.join(files, "\n")
                Logger.error("Bundle #{bf.path} contains corrupted files:\n#{files}")
                {:error, bf}
            end
          _ ->
            Logger.error("Bundle #{bf.path} did not expand into expected install directory #{install_dir}")
            {:error, bf}
        end
      error ->
        Logger.error("Expanding bundle #{bf.path} into #{bf.installed_path} failed: #{inspect error}")
        :error
    end
  end

  defp set_permssions_for_executables(install_dir, config) do
    Enum.reduce(config["commands"], :ok, &(set_permission_for_executable(install_dir, &1, &2)))
  end

  defp set_permission_for_executable(install_dir, command, :ok) do
    executable = Path.join(install_dir, command["executable"])
    File.chmod(executable, 0o755)
  end
  defp set_permission_for_executable(_, _, error) do
    error
  end

  defp register_and_start_bundle(bf, config) when is_binary(bf) do
    register_and_start_bundle2(bf, config)
  end
  defp register_and_start_bundle(bf, config) do
    commands = for command <- Map.get(config, "commands", []) do
      Map.put(command, "executable", Path.join(bf.installed_path, command["executable"]))
    end
    config = Map.put(config, "commands", commands)
    case register_and_start_bundle2(bf.installed_path, config) do
      {:ok, _} ->
        {:ok, bf}
      {:error, _} ->
        {:error, bf}
    end
  end

  defp register_and_start_bundle2(installed_path, config) do
    case Catalog.install(config, installed_path) do
      :ok ->
        name = config["bundle"]["name"]
        case Runner.start_bundle(name, installed_path) do
          {:ok, _} ->
            case Announcer.announce(config) do
              :ok ->
                {:ok, installed_path}
              error ->
                Logger.error("Error announcing bundle #{installed_path}: #{inspect error}")
                {:error, installed_path}
            end
          error ->
            Logger.error("Error starting command bundle #{installed_path}: #{inspect error}")
            {:error, installed_path}
        end
      error ->
        Logger.error("Error registering bundle #{installed_path}: #{inspect error}")
        {:error, installed_path}
    end
  end

  defp verify_executables(bf, config) do
    verify_executables(bf, config, config["commands"], [])
  end

  defp verify_executables(_bf, config, [], commands) do
    commands = Enum.reverse(commands)
    {:ok, Map.put(config, "commands", commands)}
  end
  defp verify_executables(bf, config, [cmd|t], accum) when is_binary(bf) do
    executable = cmd["executable"]
    if File.regular?(executable) do
      verify_executables(bf, config, t, [cmd|accum])
    else
      {:error, {:missing_file, cmd["name"], executable}}
    end
  end
  defp verify_executables(bf, config, [cmd|t], accum) do
    executable = cmd["executable"]
    if File.regular?(executable) do
      verify_executables(bf, config, t, [cmd|accum])
    else
      case BundleFile.find_file(bf, executable) do
        nil ->
          {:error, {:missing_file, cmd["name"], executable}}
        updated ->
          cmd = Map.put(cmd, "executable", updated)
          verify_executables(bf, config, t, [cmd|accum])
      end
    end
  end

  defp run_install_hook(bf, config) do
    bundle = config["bundle"]
    case Map.get(bundle, "install") do
      nil ->
        :ok
      script ->
        run_install_script(bf, script)
    end
  end

  defp run_install_script(bf, script) when is_binary(bf) do
    run_script(script)
  end
  defp run_install_script(bf, script) do
    {script, rest} = case String.split(script, " ") do
                       [^script] ->
                         {script, []}
                       [script|t] ->
                         {script, t}
                     end
    installed_script = Path.join(bf.installed_path, script)
    cond do
      File.regular?(script) ->
        run_script(Enum.join([script|rest], " "))
      File.regular?(installed_script) ->
        File.chmod(installed_script, 0o755)
        run_script(Enum.join([installed_script|rest], " "))
      true ->
        Logger.error("Install script #{script} not found for installed bundle #{bf.installed_path}")
        :error
    end
  end

  defp run_script(script) do
    result = Porcelain.shell(script, err: :out)
    if result.status == 0 do
      Logger.info("Install script #{script} completed: " <> result.out)
      :ok
    else
      Logger.error("Install script #{script} exited with status #{result.status}: " <> result.out)
      :error
    end
  end

  defp build_install_dest(bundle_root, config, simple? \\ false) do
    ext = if simple? do
      ".json"
    else
      ""
    end
    bundle = config["bundle"]
    name = bundle["name"] <> ext
    Path.join([bundle_root, name])
  end

  defp lock_bundle(bundle_path) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    locked_file = Path.basename(bundle_path) <> ".locked"
    locked_path = Path.join(bundle_root, locked_file)
    if File.regular?(locked_path) == true do
      Logger.warn("Skipping bundle #{bundle_path} as lock file #{locked_path} already exists")
      :stop
    else
      case File.rename(bundle_path, locked_path) do
        :ok ->
          {:ok, locked_path}
        error ->
          Logger.error("Error locking bundle #{bundle_path}: #{inspect error}")
          :stop
      end
    end
  end

  defp check_bundle_file(file_path) do
    case File.regular?(file_path) do
      true ->
        case File.open(file_path) do
          {:ok, fd} ->
            File.close(fd)
            :ok
          {:error, _} ->
            {:error, {:unable_to_open, file_path}}
        end
      false ->
        {:error, {:missing_file, file_path}}
    end
  end

end
