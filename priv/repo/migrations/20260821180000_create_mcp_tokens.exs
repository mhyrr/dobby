defmodule Dobby.Repo.Migrations.CreateMcpTokens do
  use Ecto.Migration

  @moduledoc """
  A key to the MCP door, minted on /admin (TK-022 layer B).

  The trust model, stated plainly: anyone on the local network presenting one
  of these is the household — the same posture Home Assistant takes with its
  own long-lived access tokens. The label is the token's second job and the
  reason the table exists even inside that no-adversary model: MCP tool calls
  log the label as the speaker, so the activity feed and a proposal's
  `confirmed_by` stay honest about which agent asked.

  Only the SHA-256 digest is stored. The plaintext is shown once at mint and
  never again — a stolen database row opens no door.
  """

  def change do
    create table(:mcp_tokens) do
      add :label, :string, null: false
      add :token_hash, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # The label is what the activity log attributes to, so two tokens with one
    # label would be two agents the record cannot tell apart.
    create unique_index(:mcp_tokens, [:label])
    create unique_index(:mcp_tokens, [:token_hash])
  end
end
