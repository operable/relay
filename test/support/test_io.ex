defmodule Relay.Test.IO do

  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__), only: [temp_dir!: 0]
    end
  end

  def temp_dir!() do
    {f, s, t} = :os.timestamp()
    path = Path.join([File.cwd!(), "test", "scratch", "#{f}#{s}#{t}"])
    File.rm_rf!(path)
    path
  end

end
