defmodule Dobby.Repo.Migrations.CreateDeviceProposals do
  use Ecto.Migration

  @moduledoc """
  A device somebody suggested and nobody has agreed to yet (TK-010, TK-018 E).

  Rows for the same reason schedules are rows: the household needs to *see*
  what is outstanding, and a proposal made on Tuesday evening has to survive the
  box being rebooted before anybody says yes on Wednesday morning. It also gives
  the proposal an id, which is the only thing a person can say "yes" *to* in a
  thread where three of them might be open at once.

  `entry` is the whole device as it would be written into `home.yaml` — string
  keys, string values, `type: "thermostat"` and never a module name. Stored as
  one blob rather than as columns because the shape belongs to the device type
  and the file format, not to this table; `device_id`, `type` and `name` are
  lifted out because those are what a list has to show and what supersession
  is decided by.
  """

  def change do
    create table(:device_proposals) do
      add :device_id, :string, null: false
      add :type, :string, null: false
      add :name, :string, null: false
      add :entry, :map, null: false

      # proposed → applied, or proposed → superseded. Expiry is not a status:
      # it is the clock's opinion about a proposal, computed at read time so it
      # cannot go stale, in the same posture `next_fire` takes on a schedule.
      add :status, :string, null: false, default: "proposed"

      # Attribution, never permission (design §10.4). Who said it out loud, and
      # then who agreed — two different people, often.
      add :proposed_by, :string, null: false
      add :confirmed_by, :string
      add :decided_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One outstanding proposal per device id, enforced rather than remembered.
    # "No, call it the dining room one" is a correction to a proposal, not a
    # second device — so the new one supersedes the old and the index makes
    # that the only reachable state.
    create unique_index(:device_proposals, [:device_id],
             where: "status = 'proposed'",
             name: :device_proposals_outstanding_index
           )

    create index(:device_proposals, [:status])
  end
end
