defmodule Relay.Bundle.Manifest do
  @manifest_file_name "manifest.json"

  @moduledoc """
  Defines the format and generation logic for a Relay command bundle
  manifest file. This file (`#{@manifest_file_name}`) contains the
  bundle-relative paths of all files within the bundle, as well as
  their SHA256 checksums.

  Example:

      {
        "files": [
          {
            "sha256": "919e559dd4bb3e7c65771c21253fe1096017e942b21402fcd7fa3b5c50720388",
            "path": "ebin/Elixir.Echo.beam"
          }
        ]
      }

  """

  @doc """
  Given a directory `root`, generate a manifest file containing
  information on all files found (recursively) in `root`. The file
  is written to `#{@manifest_file_name}` in `root`.

  Generally, this is the main function that will be used externally
  from this module.
  """
  def write_manifest(root) do
    files = all_files(root)
    manifest = manifest(files, root)
    write_file(manifest, root)
  end

  @doc """
  Generate a manifest data structure for all `files`. All files must
  be located in `root`.
  """
  def manifest(files, root),
    do: %{"files" => Enum.map(files, &entry(&1, root))}

  defp entry(file, root) do
    %{"path" => Path.relative_to(file, root),
      "sha256" => checksum_file(file)}
  end

  @doc """
  Writes the manifest out to `#{@manifest_file_name}` in
  `root`.
  """
  def write_file(manifest, root) do
    contents = Poison.encode!(manifest, pretty: true)
    File.write!(Path.join(root, @manifest_file_name),
                contents)
  end

  @doc """
  Generate the SHA256 checksum of the contents of `file`, encoded in
  hexadecimal.
  """
  def checksum_file(file) do
    contents = File.read!(file)
    :crypto.hash(:sha256, contents)
    |> Base.encode16
    |> String.downcase
  end

  @doc """
  Return the paths for the non-directory files in `root`.
  """
  def all_files(root) do
    Path.wildcard("#{root}/**")
    |> Enum.reject(&File.dir?/1)
  end
end
