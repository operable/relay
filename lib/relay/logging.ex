defmodule Relay.Logging do

  defmacro __using__(_) do
    quote do
      require Logger
      import unquote(__MODULE__), only: [ready: 1]
    end
  end

  defmacro ready(value) do
    quote bind_quoted: [value: value] do
      Logger.info("ready.")
      value
    end
  end

  def format(level, msg, {date, time}, metadata) do
    "#{format_date(date)} #{format_time(time)}"
    <> format_metadata(metadata)
    <> "#{level} #{msg}\n"
  end

  def json(level, msg, {date, time}, metadata) do
    Poison.encode!(add_metadata(%{date: format_date(date),
                                  time: format_time(time),
                                  level: "#{level}",
                                  message: "#{msg}"}, metadata)) <> "\n"
  end

  defp format_metadata(metadata) do
    module = Keyword.get(metadata, :module)
    line = Keyword.get(metadata, :line)
    if module != nil and line != nil do
      " (#{module}:#{line}) "
    else
      " () "
    end
  end

  defp add_metadata(entry, metadata) do
    module = Keyword.get(metadata, :module)
    line = Keyword.get(metadata, :line)
    if module != nil and line != nil do
      entry
      |> Map.put(:module, "#{module}")
      |> Map.put(:line, line)
    else
      entry
    end
  end

  defp format_date({year, month, day}) do
    "#{month}-#{day}-#{year}"
  end

  defp format_time({hour, min, sec}) do
    "#{hour}:#{min}:#{sec}"
  end
  defp format_time({hour, min, sec, micro}) do
    "#{hour}:#{min}:#{sec}:#{micro}"
  end

end
