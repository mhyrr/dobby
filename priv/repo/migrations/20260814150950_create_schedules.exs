defmodule Dobby.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  @moduledoc """
  The repo's first table (design §9, §12 Phase A step 3).

  A schedule is a row rather than a Home Assistant automation on purpose: the
  household needs to *see* its schedules, and rows give the admin dashboard
  that for free. The model authors these; `SchedulerAgent` fires them with no
  model involved.
  """

  def change do
    create table(:schedules) do
      add :label, :string, null: false
      add :cron, :string, null: false
      add :timezone, :string, null: false

      # The typed device action, stored flat rather than as one nested blob:
      # the admin dashboard wants to filter by device, and `target` is the
      # column a stale schedule is found by when a device leaves the manifest.
      # `args` stays a map because its shape belongs to the device action.
      add :target, :string, null: false
      add :action, :string, null: false
      add :args, :map, null: false, default: %{}

      add :enabled, :boolean, null: false, default: true

      # Attribution, never permission (design §10.4).
      add :created_by, :string, null: false
      add :created_via, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One namespace for names, same rule the manifest applies to devices: two
    # schedules called "weeknight heat" is a configuration mistake, not a
    # clarification opportunity. It is also what lets a person say "pause the
    # weeknight heat one" and have it resolve.
    create unique_index(:schedules, ["lower(label)"], name: :schedules_label_index)

    create index(:schedules, [:target])
  end
end
