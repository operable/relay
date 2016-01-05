defmodule Relay.ConfigurationException do
  defexception [:message]

  defmacro new(message) do
    file_name = __CALLER__.file
    line = __CALLER__.line
    quote bind_quoted: [file_name: file_name, line: line, message: message] do
      %Relay.ConfigurationException{message: "#{message} (#{file_name}:#{line})"}
    end
  end
end
