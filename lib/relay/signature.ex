defmodule Relay.Signature do

  alias Relay.Credentials
  alias Relay.Util

  @doc "Signs a JSON object using `Relay.Credentials`"
  @spec sign(Map.t(), Credentials.t()) :: Dict.t() | no_return()
  def sign(obj, %Credentials{}=creds) when is_map(obj) do
    sign(obj, creds.private)
  end

  @doc "Signs a JSON object"
  @spec sign(Map.t(), binary()) :: Dict.t() | no_return()
  def sign(obj, key) when is_map(obj) do
    text = encode!(obj)
    sig = :enacl.sign_detached(text, key)
    sig = Util.binary_to_hex_string(sig)
    %{data: obj, signature: sig}
  end

  @doc "Verify JSON object signature"
  @spec verify(Map.t(), binary()) :: boolean() | no_return()
  def verify(%{data: obj, signature: sig}, key) when is_map(obj) do
    sig = Util.hex_string_to_binary(sig)
    text = encode!(obj)
    case :enacl.sign_verify_detached(sig, text, key) do
      {:ok, ^text} ->
        true
      _ ->
        false
    end
  end

  @spec encode!(Map.t()) :: binary() | no_return()
  defp encode!(obj) do
    Poison.encode!(obj)
    |> String.codepoints
    |> Enum.filter(fn(cp) -> String.match?(cp, ~r/(\s|\:|\"|{|})/) == false end)
    |> Enum.sort
    |> List.to_string
  end

end
