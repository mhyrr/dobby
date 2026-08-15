defmodule Dobby.Conversation.Speaker do
  @moduledoc """
  A person in the household (design §10.2).

  Attribution only. There is nothing here to authenticate against and nothing
  a speaker is allowed to do that another speaker is not — that is the design's
  flat-trust rule, and the schema is where it either holds or quietly stops
  holding. If a permission column ever appears here, the Wi-Fi password stopped
  being the trust boundary and §10.2 needs rewriting first.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "speakers" do
    field :name, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Casts and validates a name.

  Names come from a text box a seven-year-old can reach, so they are trimmed
  and length-bounded here rather than trusted.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(speaker, attrs) do
    speaker
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 40)
    |> unique_constraint(:name, name: :speakers_name_index)
  end
end
