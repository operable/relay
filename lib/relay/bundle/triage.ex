defmodule Relay.Bundle.Triage do

  use Adz
  alias Relay.Bundle.Catalog

  @doc"This function moves up a potential bundle from the pending directory to the failed directory
  when it is determined that it is not ready to be transported to Cog."
  def cleanup_failed_install(bundle_name) do
    if String.ends_with?(bundle_name, Spanner.skinny_bundle_extension()) or String.ends_with?(bundle_name, "#{Spanner.skinny_bundle_extension()}.locked") do
      cleanup_failed_skinny_bundle(bundle_name)
    else
      cleanup_failed_bundle(bundle_name)
    end
  end

  @doc"This function cleans up an already installed bundle after it failed installation in Cog."
  def remove_bundles(bundles) do
    Logger.error("Failed to install the following bundles: #{inspect bundles}")
    Enum.map(bundles, &remove_bundle(&1))
  end

  defp remove_bundle(bundle) do
    Relay.Bundle.InstallHelpers.deactivate(bundle)
    move_to_failed!(bundle)
    cleanup_failed_install(bundle)
  end

  defp move_to_failed!(bundle) do
    installed_path = Catalog.installed_path(bundle)
    failed_loc = Path.join(Application.get_env(:relay, :triage_bundle_root), bundle)
    File.rename(installed_path, failed_loc)
    Logger.info("Moved the bundle `#{bundle}` to the failed directory.")
  end

  defp cleanup_failed_skinny_bundle(file_name) do
    [bundle_name|_] = String.split(file_name, ".", parts: 2)
    Catalog.uninstall(Path.basename(bundle_name))
    triage_bundle(file_name)
  end

  defp cleanup_failed_bundle(bundle_name) do
    Logger.debug("Cleaning up #{inspect bundle_name} bundle")
    bundle_root = Application.get_env(:relay, :bundle_root)
    Catalog.uninstall(bundle_name)
    triage_bundle(bundle_name)
    File.rm_rf(Path.join(bundle_root, bundle_name))
  end

  defp triage_bundle(bundle) do
    pending_root = Application.get_env(:relay, :pending_bundle_root)
    bundle_root = Application.get_env(:relay, :bundle_root)
    triage_root = Application.get_env(:relay, :triage_bundle_root)

    ensure_triage_root()
    triage_file = make_triage_file(triage_root, bundle)

    if File.exists?(bundle) do
      triage_bundle(bundle, triage_file)
    else
      pending_file = build_bundle_path(pending_root, bundle)
      installed_file = build_bundle_path(bundle_root, bundle)
      locked_file = pending_file <> ".locked"
      cond do
        File.exists?(locked_file) ->
          triage_bundle(locked_file, triage_file)
        File.exists?(pending_file) ->
          triage_bundle(pending_file, triage_file)
        File.exists?(installed_file) ->
          triage_bundle(pending_file, triage_file)
        true ->
          true
      end
    end
  end

  defp triage_bundle(source, dest) do
    ensure_triage_root()
    case File.rename(source, dest) do
      :ok ->
        Logger.info("Failed bundle #{source} triaged to #{dest}")
        true
      _error ->
        Logger.error("Error triaging failed bundle #{source} to #{dest}")
        case File.rm_rf(source) do
          {:ok, _} ->
            Logger.info("Stubborn failed bundle #{source} has been deleted")
            true
          error ->
            Logger.error("Deleting failed bundle #{source} failed: #{inspect error}")
            false
        end
    end
  end

  defp make_triage_file(triage_root, bundle_name) do
    make_triage_file(triage_root, bundle_name, 0)
  end

  defp make_triage_file(triage_root, bundle_name, n) do
    triage_file = cond do
      String.ends_with?(bundle_name, Spanner.skinny_bundle_extension()) ->
        Path.join(triage_root, Path.basename(bundle_name) <> triage_suffix(n))
      String.ends_with?(bundle_name, "#{Spanner.skinny_bundle_extension()}.locked") ->
        Path.join(triage_root, Path.basename(bundle_name) <> triage_suffix(n))
      true ->
        Path.join(triage_root, bundle_name <> ".cog" <> triage_suffix(n))
    end
    if File.exists?(triage_file) do
      make_triage_file(triage_root, bundle_name, n + 1)
    else
      triage_file
    end
  end

  defp build_bundle_path(root_dir, bundle) do
    bundle = Path.basename(bundle)
    if String.ends_with?(bundle, Spanner.skinny_bundle_extension()) or String.ends_with?(bundle, ".cog") do
      Path.join(root_dir, bundle)
    else
      Path.join(root_dir, bundle <> ".cog")
    end
  end

  defp triage_suffix(0), do: ""
  defp triage_suffix(n), do: "." <> Integer.to_string(n)

  defp ensure_triage_root() do
    triage_root = Application.get_env(:relay, :triage_bundle_root)
    File.mkdir_p(triage_root)
  end

end
