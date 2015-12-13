defmodule Relay.SignatureTest do

  alias Relay.Signature

  use ExUnit.Case

  setup_all do
    {:ok, %{creds: Relay.Credentials.generate_credentials(),
            other_creds: Relay.Credentials.generate_credentials()}}
  end

  defmacrop verify_signature_envelope(signed, original) do
    quote bind_quoted: [signed: signed, original: original], location: :keep do
      assert signed != original
      assert signed.data == original
      assert is_binary(signed.signature)
    end
  end

  test "signing maps (JSON objects)", context do
    obj = %{first_name: "Bob", last_name: "Bobbington"}
    signed = Signature.sign(obj, context.creds)
    verify_signature_envelope(signed, obj)
  end

  test "verifying signed JSON objects", context do
    obj = %{first_name: "Bob", last_name: "Bobbington"}
    signed = Signature.sign(obj, context.creds)
    verify_signature_envelope(signed, obj)
    assert Signature.verify(signed, context.creds.public)
  end

  test "fail verifying signed JSON object with wrong key", context do
    obj = %{first_name: "Bob", last_name: "Bobbington"}
    signed = Signature.sign(obj, context.creds)
    verify_signature_envelope(signed, obj)
    refute Signature.verify(signed, context.other_creds.public)
  end

end
