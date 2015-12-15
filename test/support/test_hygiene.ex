defmodule Relay.Test.Hygiene do

  defmacro __using__(_) do
    quote do

      use ExUnit.Case

      setup_all do
        scratch_dir = Path.join([File.cwd!(), "test", "scratch", "*"])
        on_exit fn ->
          for file <- Path.wildcard(scratch_dir), do: File.rm_rf(file)
        end
      end
    end
  end

end
