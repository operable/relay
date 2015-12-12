defmodule Relay.Credentials do
  alias Relay.SecurityError
  alias Relay.FileError
  alias Relay.Util

  defstruct [:private, :public]

  @private_key "relay_priv.key"
  @public_key "relay_pub.key"
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
        read_keys!(root)
      else
        raise FileError.new("Path #{root} is not a directory")
      end
    else
      File.mkdir_p!(root)
      File.chmod(root, 0o700)
      keypair = generate_keypair()
      write_key!(keypair.private, Path.join(root, @private_key))
      write_key!(keypair.public, Path.join(root, @public_key))
      keypair
    end
  end

  @doc "Generates a new private/public keypair"
  @spec generate_keypair() :: %__MODULE__{}
  def generate_keypair() do
    keys = :enacl.sign_keypair()
    %__MODULE__{private: keys.secret, public: keys.public}
  end

  @spec read_keys!(String.t()) :: %__MODULE__{} | no_return()
  defp read_keys!(root) do
    priv_key = validate_key!(Path.join(root, @private_key))
    pub_key = validate_key!(Path.join(root, @public_key))
    %__MODULE__{private: priv_key, public: pub_key}
  end

  @spec validate_key!(String.t()) :: binary() | no_return()
  defp validate_key!(path) do
    stat = File.stat!(path)
    if stat.size < @key_hash_size + 32 do
      raise SecurityError.new("Key file #{path} is likely corrupted. Please generate a new keypair.")
    end
    ensure_correct_mode!(path, 0o100600)
    raw_key = File.read!(path)
    case verify_key_checksum(raw_key) do
      :error ->
        raise SecurityError.new("Key #{path} is corrupted. Please generate a new keypair.")
      key ->
        key
    end
  end

  @spec verify_key_checksum(binary()) :: binary() | :error
  defp verify_key_checksum(raw_key) do
    <<hash::binary-size(@key_hash_size), key::binary>> = raw_key
    if :enacl.hash(key) == hash do
      key
    else
      :error
    end
  end

  @spec write_key!(binary(), String.t()) :: String.t() | no_return()
  defp write_key!(key, path) do
    contents = :erlang.list_to_binary([:enacl.hash(key), key])
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
