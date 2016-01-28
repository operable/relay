defmodule Relay.Bundle.Catalog do
  @moduledoc """
  Maintains the canonical record of deploy bundles for a given
  Relay container.
  """

  use GenServer
  use Adz

  @db_version "1.0"
  @dets_options [access: :read_write, estimated_no_objects: 64,
                 auto_save: 30000, ram_file: true]

  defstruct [:db]

  def start_link(),
  do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def installed?(bundle_name) do
    GenServer.call(__MODULE__, {:installed, bundle_name}, :infinity)
  end

  def install(bundle_config, path) do
    GenServer.call(__MODULE__, {:install, bundle_config, path}, :infinity)
  end

  def uninstall(bundle_name) do
    GenServer.call(__MODULE__, {:uninstall, bundle_name}, :infinity)
  end

  def bundle_config(bundle_name) do
    GenServer.call(__MODULE__, {:bundle_config, bundle_name}, :infinity)
  end

  def list_bundles() do
    GenServer.call(__MODULE__, :list_bundles, :infinity)
  end

  def all_bundles() do
    GenServer.call(__MODULE__, :all_bundles, :infinity)
  end

  def list_commands(bundle_name) do
    GenServer.call(__MODULE__, {:list_commands, bundle_name}, :infinity)
  end

  def installed_path(bundle_name) do
    GenServer.call(__MODULE__, {:installed_path, bundle_name}, :infinity)
  end

  def init(_) do
    File.mkdir_p!(Application.get_env(:relay, :bundle_root))
    data_root = Application.get_env(:relay, :data_root)
    if not(File.exists?(data_root)) do
      initialize_data(data_root)
    else
      verify_data(data_root)
    end
  end

  def handle_call({:install, bundle_config, path}, _from, %__MODULE__{db: db}=state) do
    bundle = Map.fetch!(bundle_config, "bundle")
    bundle_name = Map.fetch!(bundle, "name")
    case :dets.insert(db, {bundle_name, %{config: bundle_config,
                                          path: path}}) do
      :ok ->
        case :dets.sync(db) do
          :ok ->
            {:reply, :ok, state}
          error ->
            :dets.delete(db, bundle_name)
            {:reply, error, state}
        end
      error ->
        Logger.error("Error registering bundle #{bundle_name}: #{inspect error}")
        {:reply, error, state}
    end
  end
  def handle_call({:list_commands, bundle_name}, _from, %__MODULE__{db: db}=state) do
    case :dets.lookup(db, bundle_name) do
      [{^bundle_name, %{config: config}}] ->
        commands = for command <- Map.fetch!(config, "commands") do
          {command["name"], command["module"]}
        end
        {:reply, commands, state}
      [] ->
        {:reply, [], state}
    end
  end
  def handle_call({:bundle_config, bundle_name}, _from, %__MODULE__{db: db}=state) do
    case :dets.lookup(db, bundle_name) do
      [{^bundle_name, %{config: config}}] ->
        {:reply, {:ok, config}, state}
      [] ->
        {:reply, {:ok, nil}, state}
    end
  end
  def handle_call(:list_bundles, _from, %__MODULE__{db: db}=state) do
    {:reply, all_keys(db), state}
  end
  def handle_call(:all_bundles, _from, %__MODULE__{db: db}=state) do
    bundles = :dets.foldl(fn(entry, acc) -> [entry|acc] end, [], db)
    {:reply, {:ok, bundles}, state}
  end
  def handle_call({:installed_path, bundle_name}, _from, %__MODULE__{db: db}=state) do
    case :dets.lookup(db, bundle_name) do
      [{^bundle_name, data}] ->
        {:reply, data.path, state}
      _ ->
        {:reply, nil, state}
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
  def handle_call({:uninstall, bundle_name}, _from, %__MODULE__{db: db}=state) do
    :dets.delete(db, bundle_name)
    Logger.info("Removed bundle `#{bundle_name}` from catalog")
    {:reply, :ok, state}
  end
  def handle_call(_, _from, state) do
    {:reply, :ignored, state}
  end

  defp initialize_data(data_root) do
    File.mkdir_p!(data_root)
    db_path = Path.join([data_root, catalog_file_name])
    case :dets.open_file(db_path, @dets_options) do
      {:ok, db} ->
        case :dets.sync(db) do
          :ok ->
            ready({:ok, %__MODULE__{db: db}})
          {:error, reason} ->
            Logger.error("Error initializing bundle catalog: #{inspect reason}")
            {:error, reason}
        end
      {:error, reason} ->
        Logger.error("Error initializing bundle catalog: #{inspect reason}")
        {:error, reason}
    end
  end

  defp verify_data(data_root) do
    case File.dir?(data_root) do
      false ->
        Logger.error("Error verifying bundle catalog: #{data_root} is not a directory")
        {:error, :bad_data_root}
      true ->
        db_path = Path.join([data_root, catalog_file_name])
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

  defp all_keys(db) do
    all_keys(db, :dets.first(db), [])
  end

  defp all_keys(_db, :"$end_of_table", accum) do
    Enum.reverse(accum)
  end
  defp all_keys(db, key, accum) do
    all_keys(db, :dets.next(db, key), [key|accum])
  end

end
