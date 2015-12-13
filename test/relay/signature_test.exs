defmodule Relay.SignatureTest do

  alias Relay.Signature

  use ExUnit.Case

  setup_all do
    {:ok, %{creds: Relay.Credentials.generate_credentials(),
            other_creds: Relay.Credentials.generate_credentials()}}
  end

  defmacrop verify_signature_envelope(signed, original, creds) do
    quote bind_quoted: [signed: signed, original: original, creds: creds], location: :keep do
      assert signed != original
      assert signed.data == original
      assert is_binary(signed.signature)
      assert signed.id == creds.id
    end
  end

  test "signing maps (JSON objects)", context do
    obj = %{first_name: "Bob", last_name: "Bobbington"}
    signed = Signature.sign(obj, context.creds)
    verify_signature_envelope(signed, obj, context.creds)
  end

  test "verifying signed JSON objects", context do
    obj = %{first_name: "Bob", last_name: "Bobbington"}
    signed = Signature.sign(obj, context.creds)
    verify_signature_envelope(signed, obj, context.creds)
    assert Signature.verify(signed, context.creds.public)
  end

  test "fail verifying signed JSON object with wrong key", context do
    obj = %{first_name: "Bob", last_name: "Bobbington"}
    signed = Signature.sign(obj, context.creds)
    verify_signature_envelope(signed, obj, context.creds)
    refute Signature.verify(signed, context.other_creds.public)
  end

end
