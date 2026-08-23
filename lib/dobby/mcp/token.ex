defmodule Dobby.MCP.Token do
  @moduledoc """
  One key to the MCP door (TK-022 layer B).

  The row is a label and a digest and nothing else. The label is the point:
  it is what every tool call made with this token is attributed as, so the
  activity feed and a proposal's `confirmed_by` name the agent rather than
  "somebody with the token". The plaintext never touches this schema —
  `Dobby.MCP.mint/1` returns it once and stores only the SHA-256.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "mcp_tokens" do
    field :label, :string
    field :token_hash, :binary

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts and validates a token row.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:label, :token_hash])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:label, :token_hash])
    |> validate_length(:label, min: 1, max: 120)
    |> unique_constraint(:label, message: "is already a token's name; revoke that one first")
    |> unique_constraint(:token_hash)
  end
end
