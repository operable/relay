defmodule Relay.Bundle.Config do
  @moduledoc """
  Interact with and generate bundle configurations.

  A bundle configuration is a map that contains the following information:

  - The bundle name
  - A list of all commands in the bundle, including the command's
    invocation name, the Elixir module that implements it, the various
    options the command may take, and the command's version
  - A list of permissions the bundle will create
  - A list of initial rules for the commands in the bundle, using the
    bundle permissions.

  ## Example

      %{bundle: %{name: "foo"},
        commands: [%{module: "Relay.Commands.AddRule",
                     name: "add-rule",
                     options: [],
                     version: "0.0.1"},
                   %{module: "Relay.Commands.Admin",
                     name: "admin",
                     options: [%{name: "add", required: false, type: "bool"},
                               %{name: "list", required: false, type: "bool"},
                               %{name: "drop", required: false, type: "bool"},
                               %{name: "id", required: false, type: "string"},
                               %{name: "arg0", required: false, type: "string"},
                               %{name: "permission", required: false, type: "string"},
                               %{name: "for-command", required: false, type: "string"}],
                     version: "0.0.1"},
                   %{module: "Relay.Commands.Builds",
                     name: "builds",
                     options: [%{name: "state", required: true, type: "string"}],
                     version: "0.0.1"},
                   %{module: "Relay.Commands.Echo",
                     name: "echo",
                     options: [],
                     version: "0.0.1"},
                   %{module: "Relay.Commands.Giphy",
                     name: "giphy",
                     options: [],
                     version: "0.0.1"},
                   %{module: "Relay.Commands.Grant",
                     name: "grant",
                     options: [%{name: "command", required: true, type: "string"},
                               %{name: "permission", required: true, type: "string"},
                               %{name: "to", required: true, type: "string"}], version: "0.0.1"},
                   %{module: "Relay.Commands.Greet",
                     name: "greet",
                     options: [],
                     version: "0.0.1"},
                   %{module: "Relay.Commands.Math",
                     name: "math",
                     options: [],
                     version: "0.0.1"},
                   %{module: "Relay.Commands.Stackoverflow",
                     name: "stackoverflow",
                     options: [],
                     version: "0.0.1"},
        permissions: ["foo:admin", "foo:read", "foo:write"],
        rules: ["when command is foo:add-rule must have foo:admin",
                "when command is foo:grant must have foo:admin"]}

  """

  # TODO: Worthwhile creating structs for this?

  require Logger
  alias Relay.GenCommand

  def commands(config), do: modules(config, "commands")

  # TODO: Scope these to avoid conflicts with pre-existing modules
  def modules(config, type) do
    for %{"module" => module} <- Map.get(config, type, []) do
      Module.concat("Elixir", module)
    end
  end

  @doc """
  Generate a bundle configuration via code introspection. Returns a
  map representing the configuration, ready for turning into JSON.

  ## Arguments

  - `name`: the name of the bundle
  - `modules`: a list of modules to be included in the bundle. This
    really only needs to be the modules implementing Commands
    since all modules in the project are currently
    packaged up. If it is all modules in the project, though, that's
    fine, since the lists get filtered as appropriate.

  """
  def gen_config(name, modules) do
    # We create single key/value pair maps for each
    # top-level key in the overall configuration, and then merge all
    # those maps together.
    Enum.reduce([gen_bundle(name),
                 gen_commands(modules),
                 gen_permissions(name, modules),
                 gen_rules(modules)],
                &Map.merge/2)
  end

  # Generate top-level bundle configuration
  defp gen_bundle(name) do
    %{"bundle" => %{"name" => name}}
  end

  # Generate the union of all permissions required by commands in the
  # bundle. Returned permissions are namespaced by the bundle name.
  defp gen_permissions(bundle_name, modules) do
    permissions = modules
    |> only_commands
    |> Enum.map(&GenCommand.permissions/1)
    |> Enum.map(&Enum.into(&1, HashSet.new))
    |> Enum.reduce(HashSet.new, &Set.union/2)
    |> Enum.map(&namespace_permission(bundle_name, &1))
    |> Enum.sort

    %{"permissions" => permissions}
  end

  defp namespace_permission(bundle_name, permission_name),
    do: "#{bundle_name}:#{permission_name}"

  # Extract rules from all commands in the bundle
  defp gen_rules(modules) do
    rules = modules
    |> only_commands
    |> Enum.flat_map(&GenCommand.rules/1)
    |> Enum.sort

    %{"rules" => rules}
  end

  # Extract all commands from `modules` and generate configuration
  # maps for them
  defp gen_commands(modules) do
    %{"commands" => Enum.map(only_commands(modules), &command_map/1)}
  end

  defp only_commands(modules),
    do: Enum.filter(modules, &GenCommand.is_command?/1)

  defp command_map(module) do
    %{"name" => module.get_command_name(),
      "primitive" => module.primitive?(),
      "version" => version(module),
      "options" => GenCommand.options(module),
      "documentation" => case Code.get_docs(module, :moduledoc) do
                           {_line, doc} ->
                             # If a module doesn't have a module doc,
                             # then it'll return a tuple of `{1, nil}`,
                             # so that works out fine here.
                             doc
                           nil ->
                             # TODO: Transition away from @moduledoc
                             # to our own thing; modules defined in
                             # test scripts apparently can access
                             # @moduledocs
                             nil
                         end,
        "module" => inspect(module)}
  end

  defp version(module) do
    version = "0.0.1"
    Logger.warn("#{inspect __MODULE__}: Using hard-coded version of `#{version}` for command `#{inspect module}`!")
    version
  end
end
