defmodule Relay.FileError do
  @moduledoc """
Used to signal incorrect file system structures such as
a path which should be a directory but is instead a file.
"""

  defexception [:message]

  def new(message) do
    %__MODULE__{message: message}
  end

end
