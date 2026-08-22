defmodule Dobby.MCP do
  @moduledoc """
  The door for someone else's AI: bearer tokens for the MCP surface (TK-022).

  The trust model, ratified plainly: a token is minted on /admin, and anyone
  presenting it on the local network is the household. We do not defend
  against a stolen token — the posture Home Assistant takes with its own
  long-lived access tokens, and this audience already lives with those. What
  the token *does* carry is attribution: each one is labeled at mint ("Ann's
  laptop"), and that label is the speaker on every tool call made with it, so
  the activity feed and a proposal's `proposed_by`/`confirmed_by` stay honest
  about which agent asked.

  ## What is stored

  Only the SHA-256 digest of the plaintext. `mint/1` returns the plaintext
  exactly once; after that not even this module can say it again. Lookup is
  by digest of whatever was presented — hashing before comparing is what
  makes the comparison's timing say nothing about the secret, the same reason
  a password table holds hashes.
  """

  import Ecto.Query

  alias Dobby.MCP.Token
  alias Dobby.Repo

  @doc """
  Mints a labeled token and returns the plaintext — the one time it exists.

  32 random bytes, URL-safe base64. The caller shows it once and lets it go;
  the row keeps the label and the digest.
  """
  @spec mint(String.t()) :: {:ok, String.t(), Token.t()} | {:error, String.t()}
  def mint(label) do
    plaintext = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case Repo.insert(Token.changeset(%Token{}, %{label: label, token_hash: digest(plaintext)})) do
      {:ok, token} -> {:ok, plaintext, token}
      {:error, changeset} -> {:error, Dobby.Changeset.error_message(changeset)}
    end
  end

  @doc """
  The label behind a presented token, or `:error` for one Dobby never minted.

  This is the whole of MCP authentication: digest the presented bytes, look
  the digest up. A revoked token has no row and gets the same `:error` as a
  made-up one — the door does not say which.
  """
  @spec verify(String.t()) :: {:ok, String.t()} | :error
  def verify(presented) when is_binary(presented) do
    case Repo.get_by(Token, token_hash: digest(presented)) do
      %Token{label: label} -> {:ok, label}
      nil -> :error
    end
  end

  def verify(_not_a_token), do: :error

  @doc """
  Every token that opens the door, oldest first — mint order is the story.
  """
  @spec list() :: [Token.t()]
  def list do
    Repo.all(from t in Token, order_by: [asc: t.id])
  end

  @doc """
  Revokes a token. The next request presenting it gets the same 401 as one
  that was never minted.
  """
  @spec revoke(integer() | String.t()) :: {:ok, Token.t()} | {:error, String.t()}
  def revoke(id) do
    case cast_id(id) do
      {:ok, id} ->
        case Repo.get(Token, id) do
          nil ->
            {:error, "there is no token #{id}"}

          token ->
            {:ok, _deleted} = Repo.delete(token)
            {:ok, token}
        end

      :error ->
        {:error, "#{inspect(id)} is not a token id"}
    end
  end

  defp cast_id(id) when is_integer(id), do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp cast_id(_other), do: :error

  defp digest(plaintext), do: :crypto.hash(:sha256, plaintext)
end
