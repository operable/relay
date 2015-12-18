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
  def start_link(name, installed_path, commands) do
    Supervisor.start_link(__MODULE__, [installed_path, commands],
                          name: supervisor_name(name))
  end


  def init([installed_path, commands]) do
    {:ok, bf} = BundleFile.open_installed(installed_path)

    if BundleFile.dir?(bf, "ebin") do
      bundle_code = BundleFile.bundle_path(bf, "ebin")
      Logger.info("Adding #{bundle_code} to code path")
      true = Code.append_path(bundle_code)
    end
    children = for {_, module} <- commands do
      worker(Module.concat("Elixir", module), [])
    end

    Logger.info("#{__MODULE__}: Starting bundle #{bf.name}")
    supervise(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 60)
  end

  # Each bundle should be unique in the system. Giving them a unique
  # name also helps identify and reference the process.
  defp supervisor_name(name),
    do: String.to_atom("bundle_#{name}_sup")
end
