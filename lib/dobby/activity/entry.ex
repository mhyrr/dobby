defmodule Dobby.Activity.Entry do
  @moduledoc """
  One thing that happened (design §10.4).

  `device` and `action` are strings rather than references on purpose: an entry
  has to stay readable after its device leaves the manifest, and a log whose
  meaning depends on current configuration is not a log.

  `kind` is a string rather than an `Ecto.Enum` for the same reason. `TK-004`'s
  diagnostic agent will want kinds this schema cannot predict, and adding a row
  type should never be a migration.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @cast [:kind, :actor, :device, :action, :args, :result, :duration_ms, :request_id]

  schema "activity_entries" do
    field :kind, :string
    field :actor, :string
    field :device, :string
    field :action, :string
    field :args, :map, default: %{}
    field :result, :map, default: %{}
    field :duration_ms, :integer
    field :request_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts and validates an entry.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @cast)
    |> validate_required([:kind])
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
  end
end
