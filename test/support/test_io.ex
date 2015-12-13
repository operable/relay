defmodule Relay.Test.IO do

  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__), only: [temp_dir!: 0]
    end
  end

  def temp_dir!() do
    path = System.tmp_dir!
    File.rm_rf!(path)
    path
  end

end
