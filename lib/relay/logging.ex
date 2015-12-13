defmodule Relay.Logging do

  defmacro __using__(_) do
    quote do
      require Logger
      import unquote(__MODULE__), only: [ready: 1]
    end
  end

  defmacro ready(value) do
    caller = __CALLER__.module
    quote bind_quoted: [caller: caller, value: value] do
      Logger.info("#{caller} ready.")
      value
    end
  end

end
