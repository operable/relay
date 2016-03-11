defmodule Relay.BundleFileTest do

  alias Relay.BundleFile

  use Relay.Test.Hygiene
  use Relay.Test.IO

  @test_bundle "github.cog"
  @locked_test_bundle "github.cog.locked"

  defp asset_dir() do
    Path.join([File.cwd!, "test", "assets"])
  end

  defp count_files_with_suffix(files, suffix) do
    files
    |> Enum.filter(&(String.ends_with?(&1, suffix)))
    |> length
  end

  defp statistics(files) do
    beam_count = count_files_with_suffix(files, ".beam")
    json_count = count_files_with_suffix(files, ".json")
    yaml_count = count_files_with_suffix(files, ".yaml")
    everything_else = files
    |> Enum.filter(fn(file) -> not(String.ends_with?(file, ".beam") or
                                   String.ends_with?(file, ".json") or
                                   String.ends_with?(file, ".yaml")) end)
    |> length
    %{beam: beam_count, json: json_count, yaml: yaml_count, misc: everything_else,
      total: length(files)}
  end

  setup do
    dir = temp_dir!
    File.mkdir_p!(dir)
    asset_path = Path.join(asset_dir, @test_bundle)
    test_bundle_path = Path.join(dir, @test_bundle)
    locked_bundle_path = Path.join(dir, @locked_test_bundle)
    File.cp!(asset_path, test_bundle_path)
    File.cp!(asset_path, locked_bundle_path)
    {:ok, %{dir: dir,
            test_bundle_path: test_bundle_path,
            locked_bundle_path: locked_bundle_path}}
  end

  test "open and close bundle file", context do
    {:ok, bf} = BundleFile.open(context.test_bundle_path)
    assert BundleFile.close(bf) == :ok
  end

  test "list directories in bundle file", context do
    {:ok, bf} = BundleFile.open(context.test_bundle_path)
    assert BundleFile.list_dirs(bf) == ["github", "github/ebin"]
    assert BundleFile.close(bf) == :ok
  end

  test "list files in bundle file", context do
    {:ok, bf} = BundleFile.open(context.test_bundle_path)
    stats = statistics(BundleFile.list_files(bf))
    assert stats.total == 106
    assert stats.beam == 104
    assert stats.json == 1
    assert stats.yaml == 1
    assert stats.misc == 0
    assert BundleFile.close(bf) == :ok
  end

  test "reading bundle manifest", context do
    {:ok, bf} = BundleFile.open(context.test_bundle_path)
    {:ok, manifest} = BundleFile.manifest(bf)
    assert is_map(manifest)
    assert BundleFile.close(bf) == :ok
  end

  test "reading bundle config", context do
    {:ok, bf} = BundleFile.open(context.test_bundle_path)
    {:ok, config} = BundleFile.config(bf)
    assert is_map(config)
    assert BundleFile.close(bf) == :ok
  end

  test "detects locked bundle", context do
    {:ok, bf} = BundleFile.open(context.locked_bundle_path)
    assert BundleFile.is_locked?(bf)
    assert BundleFile.close(bf) == :ok
  end

  test "unlocks bundle", context do
    File.rm!(context.test_bundle_path)
    {:ok, bf} = BundleFile.open(context.locked_bundle_path)
    assert BundleFile.is_locked?(bf)
    {:ok, bf} = BundleFile.unlock(bf)
    refute BundleFile.is_locked?(bf)
    assert bf.path == context.test_bundle_path
  end

  test "unlocking bundle defaults to not overwriting", context do
    {:ok, bf} = BundleFile.open(context.locked_bundle_path)
    assert BundleFile.is_locked?(bf)
    assert BundleFile.unlock(bf) == {:error, :unlocked_bundle_exists}
    assert BundleFile.close(bf)
  end

  test "unlocking bundle w/overwrite succeeds", context do
    {:ok, bf} = BundleFile.open(context.locked_bundle_path)
    assert BundleFile.is_locked?(bf)
    {:ok, bf} = BundleFile.unlock(bf, overwrite: true)
    refute BundleFile.is_locked?(bf)
    assert BundleFile.close(bf)
  end

  test "verifying file checksums works", context do
    {:ok, bf} = BundleFile.open(context.test_bundle_path)
    install_dir = temp_dir!
    {:ok, bf} = BundleFile.expand_into(bf, install_dir)
    assert BundleFile.verify_installed_files(bf)
  end

end
