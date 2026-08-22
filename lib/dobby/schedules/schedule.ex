defmodule Dobby.Schedules.Schedule do
  @moduledoc """
  One schedule (design §9).

  A cron expression, a typed device action, and who asked for it. The model
  authors these rows and `Dobby.SchedulerAgent` fires them; nothing about
  firing consults a model, which is the whole point of storing the decision
  rather than re-deciding it at eight o'clock.

  The integer primary key is deliberate. These ids are handed to a language
  model and read back from it — `3` survives that round trip in a way a UUID
  does not, and the household is not going to author two billion schedules.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Dobby.Schedules.Cron

  @type t :: %__MODULE__{}

  @cast [:label, :cron, :timezone, :target, :action, :args, :enabled, :created_by, :created_via]
  @required [:label, :cron, :timezone, :target, :action, :created_by, :created_via]

  schema "schedules" do
    field :label, :string
    field :cron, :string
    field :timezone, :string

    field :target, :string
    field :action, :string
    field :args, :map, default: %{}

    field :enabled, :boolean, default: true

    field :created_by, :string
    field :created_via, Ecto.Enum, values: [:conversation, :admin, :mcp]

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Shape only.

  Whether `thermostat:main` exists and accepts `set_temperature` is a question
  about the house, and `Dobby.Schedules` asks it — see
  `Dobby.Schedules.validate_device_action/1`. Keeping the split means this
  function stays true regardless of which house is booted.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, @cast)
    |> validate_required(@required)
    |> validate_length(:label, min: 1, max: 120)
    |> validate_cron()
    |> validate_timezone()
    |> unique_constraint(:label, name: :schedules_label_index)
  end

  defp validate_cron(changeset) do
    validate_change(changeset, :cron, fn :cron, cron ->
      case Cron.parse(cron) do
        {:ok, _parsed} -> []
        {:error, reason} -> [cron: reason]
      end
    end)
  end

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, timezone ->
      if Cron.valid_timezone?(timezone),
        do: [],
        else: [timezone: "#{inspect(timezone)} is not a known timezone"]
    end)
  end
end
