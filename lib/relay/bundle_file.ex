defmodule Relay.BundleFile do

  @moduledoc """
This module models a command bundle file. It provides functions for
extracting `#{Spanner.Config.file_name()}` and `manifest.json`, validating bundle file
structure, unlocking and expanding bundle files on disk.
  """

  require Record

  Record.defrecord(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))
  Record.defrecord(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))

  defstruct [:name, :path, :fd, :installed_path, :files]

  @zip_options [:cooked, :memory]

  @doc "Opens a bundle file."
  @spec open(String.t()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def open(path) do
    bundle_extension = Spanner.bundle_extension()
    name = path
    |> Path.basename
    |> String.replace(Regex.compile!("#{bundle_extension}$"), "")
    |> String.replace(Regex.compile!("#{bundle_extension}.locked$"), "")
    case :zip.zip_open(cl(path), @zip_options) do
      {:ok, fd} ->
        bf = %__MODULE__{path: path, fd: fd, name: name}
        {:ok, %{bf | files: list_files(bf)}}
      error ->
        error
    end
  end

  @doc "Returns true if file reference is a bundle file handle"
  @spec bundle_file?(term()) :: boolean()
  def bundle_file?(%__MODULE__{}), do: true
  def bundle_file?(_), do: false

  @doc "Returns internal path to file if it exists"
  @spec find_file(%__MODULE__{}, String.t()) :: String.t() | boolean()
  def find_file(%__MODULE__{name: name, files: files}, path) do
    updated = Path.join(name, path)
    if Enum.member?(files, updated) do
      path
    else
      nil
    end
  end

  @doc "Extracts and parses manifest file."
  @spec manifest(%__MODULE__{}) :: {:ok, Map.t()} | {:error, term()}
  def manifest(%__MODULE__{fd: fd, name: name}) do
    path = zip_path(name, "manifest.json")
    {:ok, {_, result}} = :zip.zip_get(cl(path), fd)
    Poison.decode(result)
  end

  @doc "Extracts and parses config file."
  @spec config(%__MODULE__{}) :: {:ok, Map.t()} | {:error, term()}
  def config(%__MODULE__{fd: fd, name: name}) do
    path = zip_path(name, Spanner.Config.file_name())
    {:ok, {_, result}} = :zip.zip_get(cl(path), fd)
    Spanner.Config.Parser.read_from_string(result)
  end

  @doc "Returns bundle's lock status."
  @spec is_locked?(%__MODULE__{}) :: boolean()
  def is_locked?(%__MODULE__{path: path}) do
    String.ends_with?(path, ".locked")
  end

  @doc """
Unlocks a locked bundle file. Defaults to failing if unlocking the bundle would
overwrite an existing file. To force overwriting use `overwrite: true` as the
second argument.
  """
  @spec unlock(%__MODULE__{}, [] | [overwrite: boolean()]) :: {:ok, %__MODULE__{}} | {:error, term()}
  def unlock(%__MODULE__{fd: fd, path: path}=bf, opts \\ [overwrite: false]) do
    case String.replace(path, ~r/\.locked$/, "") do
      ^path ->
        {:error, :not_locked}
      unlocked_path ->
        case continue_renaming?(unlocked_path, opts) do
          :ok ->
            :zip.zip_close(fd)
            case File.rename(path, unlocked_path) do
              :ok ->
                case :zip.zip_open(cl(unlocked_path), @zip_options) do
                  {:ok, fd} ->
                    {:ok, %{bf | path: unlocked_path, fd: fd}}
                  error ->
                    error
                end
              error ->
                error
            end
          error ->
            error
        end
    end
  end

  @doc "Lists all unique directories contained in the bundle."
  @spec list_dirs(%__MODULE__{}) :: [String.t()]
  def list_dirs(%__MODULE__{}=bundle) do
    list_paths(bundle, :directory)
  end

  @doc "Lists all files contained in the bundle."
  @spec list_files(%__MODULE__{}) :: [String.t()]
  def list_files(%__MODULE__{}=bundle) do
    list_paths(bundle, :regular)
  end

  @doc "Verify installed files match their manifest.json checksums"
  @spec verify_installed_files(%__MODULE__{}) :: :ok | {:error, :not_installed} | {:failed, [String.t()]}
  def verify_installed_files(%__MODULE__{installed_path: nil}) do
    {:error, :not_installed}
  end
  def verify_installed_files(%__MODULE__{installed_path: path}=bf) do
    {:ok, manifest} = manifest(bf)
    files = Map.fetch!(manifest, "files")
    case Enum.reduce(files, [], fn(file, acc) ->
          verify_checksum(path, file, acc) end) do
      [] ->
        :ok
      failing_files ->
        {:failed, failing_files}
    end
  end


  @doc "Expands a bundle into the target directory"
  @spec expand_into(%__MODULE__{}, String.t()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def expand_into(%__MODULE__{path: path}=bf, target_dir) do
    case :zip.unzip(cl(path), [{:cwd, cl(target_dir)}]) do
      {:ok, _} ->
        installed_path = Path.join(target_dir, bf.name)
        {:ok, %{bf | installed_path: installed_path}}
      error ->
        error
    end
  end

  @doc "Determines if bundle-relative path is a file"
  @spec file?(%__MODULE__{}, String.t()) :: boolean() | {:error, :not_installed} | {:error, :bad_path}
  def file?(%__MODULE__{installed_path: nil}, _) do
    {:error, :not_installed}
  end
  def file?(%__MODULE__{installed_path: installed_path}, relpath) do
    case bundle_path(installed_path, relpath) do
      {:error, _} = error ->
        error
      path ->
        File.file?(path)
    end
  end

  @doc "Determines if bundle-relative path is a dir"
  @spec dir?(%__MODULE__{}, String.t()) :: boolean() | {:error, :not_installed} | {:error, :bad_path}
  def dir?(%__MODULE__{installed_path: nil}, _) do
    {:error, :not_installed}
  end
  def dir?(%__MODULE__{}=bf, relpath) do
    case bundle_path(bf, relpath) do
      {:error, _} = error ->
        error
      path ->
        File.dir?(path)
    end
  end

  @doc "Builds a bundle-relative path. Ensures path does not escape bundle directory."
  def bundle_path(%__MODULE__{installed_path: installed_path}, relpath) do
    # Ensure relpath doesn't begin with "/"
    installed_path = Path.absname(installed_path)
    relpath = String.replace(relpath, ~r/\A\//, "")
    # Expand ellipses, if any
    path = Path.expand(Path.absname(relpath, installed_path))
    if String.starts_with?(path, installed_path) do
      path
    else
      {:error, :bad_path}
    end
  end


  @doc "Closes all file handles associated with the bundle."
  @spec close(%__MODULE__{}) :: :ok
  def close(%__MODULE__{}=file) do
    :zip.zip_close(file.fd)
    :ok
  end

  defp continue_renaming?(unlocked_path, [overwrite: false]) do
    case File.exists?(unlocked_path) do
      true ->
        {:error, :unlocked_bundle_exists}
      false ->
        :ok
    end
  end
  defp continue_renaming?(unlocked_path, [overwrite: true]) do
    case File.exists?(unlocked_path) do
      true ->
        case File.regular?(unlocked_path) do
          true ->
            File.rm!(unlocked_path)
            :ok
          false ->
            {:error, :bad_unlocked_bundle_file}
        end
      false ->
        :ok
    end
  end

  defp list_paths(%__MODULE__{fd: fd}, type) do
    {:ok, [_|paths]} = :zip.zip_list_dir(fd)
    paths
    |> Enum.filter(&(is_type?(&1, type)))
    |> Enum.map(&(zip_dir_path(&1, type)))
    |> Enum.uniq
  end

  defp zip_path(name, file) when is_binary(file) do
    Enum.join([name, file], "/")
  end

  defp cl(s) when is_binary(s) do
    String.to_char_list(s)
  end

  defp zip_dir_path(zf, :regular) do
    zip_file(name: name) = zf
    String.Chars.List.to_string(name)
  end
  defp zip_dir_path(zf, :directory) do
    zip_file(name: name) = zf
    Path.dirname(String.Chars.List.to_string(name))
  end

  defp is_type?(zf, type) do
    zip_file(info: info) = zf
    file_info(type: zf_type) = info
    zf_type == type
  end

  defp verify_checksum(install_path, entry, acc) do
    checksum = Map.fetch!(entry, "sha256")
    file_path = Map.fetch!(entry, "path")
    full_path = Path.join(install_path, file_path)
    contents = File.read!(full_path)
    file_checksum = :crypto.hash(:sha256, contents)
    |> Base.encode16
    |> String.downcase
    if file_checksum != checksum do
      [full_path|acc]
    else
      acc
    end
  end

end
