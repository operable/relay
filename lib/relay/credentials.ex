defmodule Relay.Credentials do
  alias Relay.SecurityError
  alias Relay.FileError
  alias Relay.Util

  defstruct [:id, :private, :public]

  @private_key "relay_priv.key"
  @public_key "relay_pub.key"
  @relay_id "relay.id"

  # 32 byte key w/64 byte checksum
  @key_hash_size 64

  @doc "Validates the configured credential directory."
  @spec validate_files!() :: true | no_return()
  def validate_files!() do
    {:ok, dir} = Application.get_env(:relay, :credentials_dir)
    validate_files!(dir)
  end

  @doc "Validates the directory structure and file permissions of credentials."
  def validate_files!(root) do
    if File.exists?(root) do
      if File.dir?(root) do
        ensure_correct_mode!(root, 0o40700)
        read_credentials!(root)
      else
        raise FileError.new("Path #{root} is not a directory")
      end
    else
      configure_credentials!(root)
    end
  end

  @doc "Generates a new private/public keypair"
  @spec generate_credentials() :: %__MODULE__{}
  def generate_credentials() do
    keys = :enacl.sign_keypair()
    %__MODULE__{id: UUID.uuid4(), private: keys.secret, public: keys.public}
  end

  @spec configure_credentials!(String.t()) :: %__MODULE__{} | no_return
  defp configure_credentials!(root) do
    File.mkdir_p!(root)
    File.chmod(root, 0o700)
    credentials = generate_credentials()
    write_credentials!(root, credentials)
  end

  @spec read_credentials!(String.t()) :: %__MODULE__{} | no_return()
  defp read_credentials!(root) do
    priv_key = read_data_checksum!(Path.join(root, @private_key))
    pub_key = read_data_checksum!(Path.join(root, @public_key))
    id = read_data_checksum!(Path.join(root, @relay_id))
    %__MODULE__{private: priv_key, public: pub_key, id: id}
  end

  @spec read_data_checksum!(String.t()) :: binary() | no_return()
  defp read_data_checksum!(path) do
    stat = File.stat!(path)
    if stat.size < @key_hash_size + 32 do
      raise SecurityError.new("Credential file #{path} is corrupted. Please generate a new credential set.")
    end
    ensure_correct_mode!(path, 0o100600)
    raw_data = File.read!(path)
    case verify_data_checksum(raw_data) do
      :error ->
        raise SecurityError.new("Credential file #{path} is corrupted. Please generate a new credential set.")
      key ->
        key
    end
  end

  @spec verify_data_checksum(binary()) :: binary() | :error
  defp verify_data_checksum(raw_data) do
    <<hash::binary-size(@key_hash_size), data::binary>> = raw_data
    if :enacl.hash(data) == hash do
      data
    else
      :error
    end
  end

  @spec write_credentials!(String.t(), %__MODULE__{}) :: %__MODULE__{} | no_return()
  defp write_credentials!(root, credentials) do
    write_data_checksum!(credentials.public, Path.join(root, @public_key))
    write_data_checksum!(credentials.private, Path.join(root, @private_key))
    write_data_checksum!(credentials.id, Path.join(root, @relay_id))
    credentials
  end

  @spec write_data_checksum!(binary(), String.t()) :: String.t() | no_return()
  defp write_data_checksum!(data, path) do
    contents = :erlang.list_to_binary([:enacl.hash(data), data])
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end

  @spec ensure_correct_mode!(String.t(), pos_integer()) :: true | no_return()
  defp ensure_correct_mode!(path, path_mode) do
    stat = File.stat!(path)
    mode = Util.convert_integer(stat.mode, 8)
    if mode != path_mode do
      raise SecurityError.new("Path #{path} should have mode #{Integer.to_string(path_mode, 8)} " <>
        "but has #{Integer.to_string(mode, 8)} instead")
    else
      true
    end
  end
end
