defmodule Relay.Config.Helpers do
  defmacro __using__(_) do
    quote do
      import Relay.Config.Helpers
    end
  end

  def data_dir do
    System.get_env("RELAY_DATA_DIR") || Path.expand(Path.join([Path.dirname(__ENV__.file), "..", "data"]))
  end

  def data_dir(subdir) do
    Path.join([data_dir, subdir])
  end

  def ensure_integer(ttl) when is_nil(ttl), do: false
  def ensure_integer(ttl) when is_binary(ttl), do: String.to_integer(ttl)
  def ensure_integer(ttl) when is_integer(ttl), do: ttl
end
