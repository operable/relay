defmodule Relay.Bundle.Sup do
  @moduledoc """
  Supervises all commands and services from a single bundle.
  """

  use Supervisor
  use Adz
  alias Relay.BundleFile

  # TODO: when / if a child dies, can we remove the plugin code from
  # the path? Or do we even bother, given that we're going to
  # transition to distributed Erlang?

  @doc """
  Start up a supervisor for the given `bundle` of commands and
  services.
  """
  def start_link(name, installed_path) do
    Supervisor.start_link(__MODULE__, [installed_path],
                          name: supervisor_name(name))
  end


  def init([installed_path]) do
    case BundleFile.open_installed(installed_path) do
      {:ok, bf} ->
        if BundleFile.dir?(bf, "ebin") do
          bundle_code = BundleFile.bundle_path(bf, "ebin")
          unless on_code_path?(bundle_code) do
            Logger.info("Adding #{bundle_code} to code path")
            true = Code.append_path(bundle_code)
          end
        end
        {:ok, config} = BundleFile.config(bf)
        bundle_name = config["bundle"]["name"]
        commands = config["commands"]
        children = for command <- commands do
          name = command["name"]
          module = Module.concat([command["module"]])
          worker(Spanner.GenCommand, [bundle_name, name, module, []], id: module)
        end
        BundleFile.close(bf)
        Logger.info("#{__MODULE__}: Starting bundle #{bf.name}")
        # Can be one_for_one until services are part of bundles; then
        # services should start first, followed by commands, and be
        # restarted rest_for_one
        supervise(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
      error ->
        Logger.error("Error starting bundle installed on path '#{installed_path}': #{inspect error}")
        error
    end
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
