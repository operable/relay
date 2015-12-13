defmodule Relay.Bundle.BundleCatalog do
  @moduledoc """
  Maintains the canonical record of deploy bundles for a given
  Relay container.
  """

  use GenServer
  use Relay.Logging

  @db_version "1.0"
  @dets_options [access: :read_write, estimated_no_objects: 64,
                 auto_save: 30000, ram_file: true]

  defstruct [:db]

  def start_link(),
  do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def installed?(bundle_name) do
    GenServer.call(__MODULE__, {:installed, bundle_name}, :infinity)
  end

  def init(_) do
    bundle_root = Application.get_env(:relay, :bundle_root)
    if not(File.exists?(bundle_root)) do
      initialize_root(bundle_root)
    else
      verify_root(bundle_root)
    end
  end

  def handle_call({:installed, bundle_name}, _from, %__MODULE__{db: db}=state) do
    reply = case :dets.lookup(db, bundle_name) do
              [] ->
                false
              _ ->
                true
            end
    {:reply, reply, state}
  end
  def handle_call(_, _from, state) do
    {:reply, :ignored, state}
  end

  defp initialize_root(bundle_root) do
    File.mkdir_p!(bundle_root)
    db_path = Path.join([bundle_root, catalog_file_name])
    case :dets.open_file(db_path, @dets_options) do
      {:ok, db} ->
        ready({:ok, %__MODULE__{db: db}})
      {:error, reason} ->
        Logger.error("Error initializing bundle catalog: #{inspect reason}")
        {:error, reason}
    end
  end

  defp verify_root(bundle_root) do
    case File.dir?(bundle_root) do
      false ->
        Logger.error("Error verifying bundle catalog: #{bundle_root} is not a directory")
        {:error, :bad_bundle_root}
      true ->
        db_path = Path.join([bundle_root, catalog_file_name])
        case valid_db_file?(db_path) do
          true ->
            case :dets.open_file(db_path, @dets_options) do
              {:ok, db} ->
                ready({:ok, %__MODULE__{db: db}})
              {:error, reason} ->
                Logger.error("Error verifying bundle catalog: #{inspect reason}")
                {:error, reason}
            end
          false ->
            {:error, :bad_catalog_db}
        end
    end
  end

  defp valid_db_file?(db_path) do
    case File.exists?(db_path) do
      true ->
        case File.regular?(db_path) do
          true ->
            case :dets.is_dets_file(db_path) do
              true ->
                true
              false ->
                Logger.error("Error verifying bundle catalog: #{db_path} is not a valid bundle database")
            end
          false ->
            Logger.error("Error verifying bundle catalog: #{db_path} is not a regular file")
            false
        end
      false ->
        Logger.error("Error verifying bundle catalog: #{db_path} is missing")
        false
    end
  end

  defp catalog_file_name() do
    "catalog_#{@db_version}.db"
  end

end
