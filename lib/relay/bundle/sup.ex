defmodule Relay.Bundle.Sup do
  @moduledoc """
  Supervises all commands and services from a single bundle.
  """

  use Supervisor
  use Adz
  alias Spanner.GenCommand

  # TODO: when / if a child dies, can we remove the plugin code from
  # the path? Or do we even bother, given that we're going to
  # transition to distributed Erlang?

  @doc """
  Start up a supervisor for the given `bundle` of commands and
  services.
  """
  def start_link(name, installed_path, config) do
    Supervisor.start_link(__MODULE__, [installed_path, config],
                          name: supervisor_name(name))
  end


  def init([installed_path, %{"bundle" => %{"name" => bundle_name},
                              "commands" => commands}]) do
    bundle_code = Path.join(installed_path, "ebin")
    if File.dir?(bundle_code) do
      unless on_code_path?(bundle_code) do
        Logger.info("Adding #{bundle_code} to code path")
        true = Code.append_path(bundle_code)
      end
    end
    children = for command <- commands do
      module_name = command["module"]
      cmd_name = command["name"]
      module = Module.concat([module_name])
      worker(GenCommand, [bundle_name, cmd_name, module, []], id: module)
    end

    Logger.info("#{__MODULE__}: Starting bundle #{bundle_name}")
    # Can be one_for_one until services are part of bundles; then
    # services should start first, followed by commands, and be
    # restarted rest_for_one
    supervise(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  # Each bundle should be unique in the system. Giving them a unique
  # name also helps identify and reference the process.
  defp supervisor_name(name),
    do: String.to_atom("bundle_#{name}_sup")

  defp on_code_path?(path) when is_binary(path) do
    on_code_path?(String.to_char_list(path))
  end
  defp on_code_path?(path) when is_list(path) do
    Enum.member?(:code.get_path(), path)
  end

end
