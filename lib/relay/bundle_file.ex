defmodule Relay.BundleFile do

  require Record

  Record.defrecord(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))
  Record.defrecord(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))

  defstruct [:name, :path, :fd]

  @zip_options [:cooked, :memory]

  def open(path) do
    name = path
    |> Path.basename
    |> String.replace(~r/.loop$/, "")
    case :zip.zip_open(cl(path), @zip_options) do
      {:ok, fd} ->
        {:ok, %__MODULE__{path: path, fd: fd, name: name}}
      error ->
        error
    end
  end

  def manifest(%__MODULE__{fd: fd, name: name}) do
    path = zip_path(name, "manifest.json")
    {:ok, {_, result}} = :zip.zip_get(cl(path), fd)
    Poison.decode(result)
  end

  def config(%__MODULE__{fd: fd, name: name}) do
    path = zip_path(name, "config.json")
    {:ok, {_, result}} = :zip.zip_get(cl(path), fd)
    Poison.decode(result)
  end

  def is_locked?(%__MODULE__{path: path}) do
    String.ends_with?(path, ".locked")
  end

  def unlock(%__MODULE__{fd: fd, path: path}) do
    case String.replace(path, ~r/\.locked$/, "") do
      ^path ->
        {:error, :not_locked}
      unlocked_path ->
        :zip.zip_close(fd)
        case File.rename(path, unlocked_path) do
          :ok ->
            case :zip.zip_open(cl(unlocked_path), @zip_options) do
              {:ok, fd} ->
                {:ok, %__MODULE__{path: unlocked_path, fd: fd}}
              error ->
                error
            end
          error ->
            error
        end
    end
  end

  def list_dirs(%__MODULE__{}=bf) do
    list_paths(bf, :directory)
  end

  def list_files(%__MODULE__{}=bf) do
    list_paths(bf, :regular)
  end

  def close(%__MODULE__{}=file) do
    :zip.zip_close(file.fd)
    :ok
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

end
