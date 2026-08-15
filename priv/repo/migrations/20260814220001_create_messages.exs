defmodule Dobby.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  @moduledoc """
  The transcript (design §10.1, §10.5).

  One shared household thread, rendered with full scrollback, and the source
  `DobbyAgent` rehydrates its recent conversation window from after a restart.

  ## One table, not two

  A system line — "main thermostat set to 70 — greg" — is a message with
  `role: :system` and a `meta` map, not its own table. Splitting them would
  mean merging two ordered reads by timestamp on every page of scrollback,
  which is the usual way this gets built and the usual way it goes wrong. One
  table, one index, one order.

  `meta` carries what a system line needs and an utterance does not: the
  device, the action taken, the outcome, and the `via` that says which path
  changed the house — a tool call, a card tap, a schedule firing, or someone
  turning the dial and Home Assistant telling us about it.

  `speaker_id` is null for Dobby's own replies and for system lines. Both have
  an author in the ordinary sense; neither has a *speaker*, and inventing a row
  for "the house" would put something in the roster that nobody can talk to.
  """

  def change do
    create table(:messages) do
      # Null for Dobby and for system lines. Nothing is deleted in a
      # transcript, so this restricts rather than nilifies: losing the
      # attribution on an old message would quietly rewrite history.
      add :speaker_id, references(:speakers, on_delete: :restrict)

      add :role, :string, null: false
      add :channel, :string
      add :text, :text, null: false

      # Correlates an utterance, its reply, and every activity entry produced
      # while answering it. Null for anything that did not come from a request.
      add :request_id, :string

      add :meta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Scrollback is the only read shape that matters: the thread is ordered by
    # time and paged backwards from now.
    create index(:messages, [:inserted_at])
    create index(:messages, [:request_id])
  end
end
