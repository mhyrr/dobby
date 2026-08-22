defmodule Dobby.MCPTest do
  @moduledoc """
  The keys to the MCP door (TK-022 layer B).

  Small on purpose, like the module: mint hands the plaintext over exactly
  once, keeps only a digest, and everything after that is lookup. The two
  properties worth pinning are the ones the trust model leans on — a stored
  row cannot open the door, and a label names exactly one key.
  """

  use Dobby.DataCase, async: true

  alias Dobby.MCP

  test "mint returns the plaintext once and stores only its digest" do
    assert {:ok, plaintext, token} = MCP.mint("the kitchen laptop")

    assert token.label == "the kitchen laptop"
    # 32 random bytes, URL-safe base64 — the shape a person will paste around.
    assert byte_size(Base.url_decode64!(plaintext, padding: false)) == 32
    # The row holds a SHA-256, never the secret: reading the database back
    # gives an attacker nothing to present.
    assert token.token_hash == :crypto.hash(:sha256, plaintext)
    refute token.token_hash == plaintext

    assert MCP.verify(plaintext) == {:ok, "the kitchen laptop"}
  end

  test "a token nobody minted opens nothing" do
    assert MCP.verify("not-a-token") == :error
    assert MCP.verify("") == :error
    assert MCP.verify(nil) == :error
  end

  test "a label names exactly one key" do
    assert {:ok, _plaintext, _token} = MCP.mint("the kitchen laptop")
    assert {:error, message} = MCP.mint("the kitchen laptop")
    assert message =~ "already a token's name"
  end

  test "a label is a name, so a blank one is refused" do
    assert {:error, message} = MCP.mint("   ")
    assert message =~ "label"
  end

  test "a label fits the database column" do
    assert {:error, message} = MCP.mint(String.duplicate("a", 121))
    assert message =~ "at most 120"
    assert MCP.list() == []
  end

  test "revoking closes the door for good" do
    {:ok, plaintext, token} = MCP.mint("the kitchen laptop")

    assert {:ok, _revoked} = MCP.revoke(token.id)
    # The same :error a made-up token gets — the door does not say which.
    assert MCP.verify(plaintext) == :error
    assert MCP.list() == []

    assert {:error, message} = MCP.revoke(token.id)
    assert message =~ "there is no token"
  end

  test "a malformed id is a refusal, not a context crash" do
    assert {:error, message} = MCP.revoke("not-an-id")
    assert message =~ "not a token id"

    assert {:error, message} = MCP.revoke(nil)
    assert message =~ "not a token id"
  end
end
