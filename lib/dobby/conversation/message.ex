defmodule Dobby.Conversation.Message do
  @moduledoc """
  One line of the household thread (design §10.2).

  Three roles share this table:

    * `:user` — somebody said something. Has a speaker and a channel.
    * `:assistant` — Dobby answered. Has neither.
    * `:system` — the house changed, by any path. Has neither, and carries the
      detail in `meta`.

  A system line is not a lesser message. It is how the thread stays honest
  about interventions it did not cause: a card tap, a schedule firing, or
  somebody turning the dial in the hallway all land here, because a transcript
  that shows the thermostat at 70 with no explanation is lying by omission.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Dobby.Conversation.Speaker

  @type t :: %__MODULE__{}

  @roles [:user, :assistant, :system]
  @channels [:web, :voice]

  @cast [:speaker_id, :role, :channel, :text, :request_id, :meta]

  schema "messages" do
    belongs_to :speaker, Speaker

    field :role, Ecto.Enum, values: @roles
    field :channel, Ecto.Enum, values: @channels
    field :text, :string
    field :request_id, :string
    field :meta, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The roles a message can have.
  """
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc """
  Casts and validates a message.

  A `:user` message must have a speaker: an utterance with nobody attached is
  either a bug in the identity plug or a channel that has not learned to say
  who is talking, and both should fail loudly here rather than appear in the
  thread as though the house said it.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, @cast)
    |> validate_required([:role, :text])
    |> validate_speaker()
    |> foreign_key_constraint(:speaker_id)
  end

  defp validate_speaker(changeset) do
    case get_field(changeset, :role) do
      :user -> validate_required(changeset, [:speaker_id])
      _other -> changeset
    end
  end
end
