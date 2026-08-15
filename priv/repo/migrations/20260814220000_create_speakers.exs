defmodule Dobby.Repo.Migrations.CreateSpeakers do
  use Ecto.Migration

  @moduledoc """
  Who is talking (design §10.2, surface design §7).

  A speaker is a person, not a device. Identity here is personalization and
  attribution and never permission — the Wi-Fi password is the trust boundary —
  so this table carries a name and nothing else. There is no role column, no
  password, and nothing to authenticate against, deliberately.

  A browser remembers which speaker it is in a cookie holding this id. That is
  the whole of device pinning: enter a name once and it sticks until someone
  switches it. An earlier draft added a `browser_devices` table to carry a
  "shared device" flag for the kitchen iPad; it was cut, because a shared
  device that occasionally attributes to the wrong housemate costs a wrong name
  in one sentence, and identity gates nothing.
  """

  def change do
    create table(:speakers) do
      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Same rule the manifest applies to devices and the scheduler applies to
    # labels: two people called "greg" in one household is a mistake, not a
    # clarification opportunity. It is also what lets a returning browser
    # resolve a typed name to the speaker who already exists.
    create unique_index(:speakers, ["lower(name)"], name: :speakers_name_index)
  end
end
