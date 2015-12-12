defmodule Relay.SecurityError do
  @moduledoc """
Used to signal security errors such as incorrect file permissions on public
or private keys.
  """
  defexception [:message]

  def new(message) do
    %__MODULE__{message: message}
  end
end
