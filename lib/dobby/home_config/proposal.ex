defmodule Dobby.HomeConfig.Proposal do
  @moduledoc """
  One device somebody suggested (TK-010).

  The model extracts it; this row holds it; `Dobby.HomeConfig.Writer` is the
  only thing that can turn it into a device. Nothing about the entry is
  interpreted here — it is the mapping a home file would contain, kept exactly
  as it was validated, so that confirming it a day later writes what was
  actually agreed to rather than what a second reading of the sentence produces.

  The integer primary key is the same decision `Dobby.Schedules.Schedule`
  makes and for the same reason: these ids are said out loud in a thread and
  read back by a language model, and `2` survives that round trip in a way a
  UUID does not.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses [:proposed, :applied, :superseded]

  @cast [:device_id, :type, :name, :entry, :status, :proposed_by, :confirmed_by, :decided_at]
  @required [:device_id, :type, :name, :entry, :status, :proposed_by]

  schema "device_proposals" do
    field :device_id, :string
    field :type, :string
    field :name, :string
    field :entry, :map

    field :status, Ecto.Enum, values: @statuses, default: :proposed

    field :proposed_by, :string
    field :confirmed_by, :string
    field :decided_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Shape only.

  Whether the entry describes a device this house can actually have is a
  question about the house, and `Dobby.HomeConfig` answers it — twice, once
  when the proposal is made and once when it is confirmed, because the house
  can change in between.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, @cast)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 120)
    |> unique_constraint(:device_id, name: :device_proposals_outstanding_index)
  end

  @doc """
  Every status a proposal can be stored in.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
