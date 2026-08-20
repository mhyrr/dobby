defmodule Dobby.Repo.Migrations.CreateActivityEntries do
  use Ecto.Migration

  @moduledoc """
  Everything that happened (design §10.6).

  The rule from §10.3 is that the thread records interventions and the admin
  records everything. This is the everything: every request, tool call, result,
  state change, and schedule firing, whether or not a person would want to read
  about it.

  It is also the table `TK-004`'s diagnostic agent reads. That agent's whole
  premise is answering "is this the third time this week", which is a question
  about history rather than about the current event — so this is written to be
  queried by device and by time, not just appended to.

  Deliberately denormalized: `device` and `action` are strings rather than
  references, because an activity entry has to stay readable after a device
  leaves the manifest. A log that loses its meaning when the house is
  reconfigured is not a log.
  """

  def change do
    create table(:activity_entries) do
      # What kind of thing happened: "request", "tool_call", "state_changed",
      # "schedule_fired", "error". A string rather than an enum because the
      # diagnostic agent will add kinds this migration cannot predict, and a
      # log should never be the reason a deploy needs a migration.
      add :kind, :string, null: false

      # Who or what caused it — a speaker name, a schedule label, or "home
      # assistant" when the house changed underneath us.
      add :actor, :string

      add :device, :string
      add :action, :string
      add :args, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}

      add :duration_ms, :integer
      add :request_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:activity_entries, [:inserted_at])
    create index(:activity_entries, [:request_id])
    # "has this device been refusing all week" is the diagnostic question.
    create index(:activity_entries, [:device, :inserted_at])
  end
end
