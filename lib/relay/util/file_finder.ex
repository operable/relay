defmodule Relay.Util.FileFinder do
  require Logger
  require Bitwise

  @moduledoc """
  Executes filesystem searches using caller-specified search criteria
  """

  defstruct dirs: []

  def make([env_var: name]) when is_binary(name) do
    name = clean_env_var(name)
    value = System.get_env(name)
    if value == nil do
      Logger.warn("Environment variable '#{name}' is not set.")
      nil
    else
      %__MODULE__{dirs: String.split(value, ":")}
    end
  end
  def make([dirs: []]) do
    Logger.warn("Directory list is empty.")
    nil
  end
  def make([dirs: dirs]) when is_list(dirs) do
    %__MODULE__{dirs: dirs}
  end

  def find(%__MODULE__{}=finder, name, opts \\ []) do
    case do_search(finder.dirs, name) do
      nil ->
        nil
      path ->
        apply_options(path, opts)
    end
  end

  defp apply_options(path, []) do
    path
  end
  defp apply_options(path, [:dir|t]) do
    if File.dir?(path) do
      apply_options(path, t)
    else
      nil
    end
  end
  defp apply_options(path, [:file|t]) do
    if File.regular?(path) do
      apply_options(path, t)
    else
      nil
    end
  end
  defp apply_options(path, [:executable|t]) do
    stat = File.stat!(path)
    cond do
      Bitwise.bor(stat.mode, 0o050) == stat.mode ->
        apply_options(path, t)
      Bitwise.bor(stat.mode, 0o005) == stat.mode ->
        apply_options(path, t)
      true ->
        nil
    end
  end

  defp clean_env_var(<<"$", name::binary>>) do
    String.upcase(name)
  end
  defp clean_env_var(name) do
    String.upcase(name)
  end

  defp do_search([], _name) do
    nil
  end
  defp do_search([path|t], name) do
    candidate = Path.join(path, name)
    cond do
      path == name ->
        path
      File.exists?(candidate) ->
        candidate
      Path.basename(path) == name ->
        path
      true ->
        do_search(t, name)
    end
  end
end
