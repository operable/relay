defmodule Relay.Bundle.Sup do
  @moduledoc """
  Supervises all commands and services from a single bundle.
  """

  use Supervisor
  use Adz
  alias Relay.Bundle.Catalog

  # TODO: when / if a child dies, can we remove the plugin code from
  # the path? Or do we even bother, given that we're going to
  # transition to distributed Erlang?

  @doc """
  Start up a supervisor for the given `bundle` of commands and
  services.
  """
  def start_link([{:bundle, bundle}|_]=opts) do
    Supervisor.start_link(__MODULE__, opts,
                          name: supervisor_name(bundle))
  end

  def init([bundle: bundle_name, foreign: bundle_dir]) do
    if File.dir?(bundle_dir) == false do
      try do
        File.mkdir_p!(bundle_dir)
      rescue
        e ->
          Logger.error("Error creating working directory #{bundle_dir} for bundle #{bundle_name}: #{inspect e}")
          reraise e, System.stacktrace
      end
    end
    {:ok, config} = Catalog.bundle_config(bundle_name)
    commands = config["commands"]
    children = for command <- commands do
      name = command["name"]
      executable = command["executable"]
      env_vars = Map.get(command, "env_vars", %{})
      args = [bundle: bundle_name, bundle_dir: bundle_dir, command: name,
              executable: executable, env: env_vars]
      id = foreign_id(bundle_name, name)
      worker(Spanner.GenCommand, [bundle_name, name, Spanner.GenCommand.Foreign, args], id: id)
    end
    supervise(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  def init([bundle: bundle_name, elixir: installed_path]) do
    bundle_code = Path.join(installed_path, "ebin")
    unless on_code_path?(bundle_code) do
      Logger.info("Adding #{bundle_code} to code path")
      true = Code.append_path(bundle_code)
    end
    {:ok, config} = Catalog.bundle_config(bundle_name)
    commands = config["commands"]
    children = for command <- commands do
      name = command["name"]
      module = Module.concat([command["module"]])
      worker(Spanner.GenCommand, [bundle_name, name, module, []], id: module)
    end
    Logger.info("#{__MODULE__}: Starting bundle #{bundle_name}")
    # Can be one_for_one until services are part of bundles; then
    # services should start first, followed by commands, and be
    # restarted rest_for_one
    supervise(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  # Each bundle should be unique in the system. Giving them a unique
  # name also helps identify and reference the process.
  def supervisor_name(name),
    do: String.to_atom("bundle_#{name}_sup")

  defp on_code_path?(path) when is_binary(path) do
    on_code_path?(String.to_char_list(path))
  end
  defp on_code_path?(path) when is_list(path) do
    Enum.member?(:code.get_path(), path)
  end

  defp foreign_id(bundle_name, name) do
    String.to_atom(Enum.join(["relay", "foreign", bundle_name, name], "."))
  end

end
