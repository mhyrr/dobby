defmodule Dobby.Rules.Proposal do
  @moduledoc """
  The exact rule a person was shown, before it watches anything.

  The previous definition detects an edit made between proposal and agreement.
  The request id prevents the household model from approving its own proposal
  in the same turn. MCP keeps its established token-as-household authority.
  """
  use Ecto.Schema

  schema "rule_proposals" do
    field(:house_id, :string)
    field(:rule_id, :string)
    field(:entry, :map)
    field(:previous, :map)
    field(:description, :string)
    field(:proposed_by, :string)
    field(:request_id, :string)
    field(:status, :string, default: "proposed")
    field(:confirmed_by, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
