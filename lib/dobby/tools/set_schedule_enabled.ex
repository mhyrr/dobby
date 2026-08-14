defmodule Dobby.Tools.SetScheduleEnabled do
  @moduledoc """
  Tool: pause or resume a schedule.

  Pausing cancels the timer and keeps the row, which is the difference between
  "not this week" and "never again". Resuming re-registers it.

  ## On being one tool rather than two

  Design §6.2 names `pause_schedule(id)` and `resume_schedule(id)` separately.
  They are one tool here because they are one operation with a flag, and two
  modules differing by a boolean is duplication looking for somewhere to drift.
  The trade is real and measurable in the eval tier: a verb per intent is one
  less thing for a model to get wrong than a boolean, and if "pause the
  weeknight heat" starts arriving as `enabled: true`, splitting them back is a
  small change.
  """

  use Jido.Action,
    name: "set_schedule_enabled",
    description: """
    Pause or resume a schedule. Pausing stops it running without deleting it; \
    resuming starts it again. Use list_schedules to find the id.\
    """,
    schema: [
      id: [type: :integer, required: true, doc: "Schedule id from list_schedules"],
      enabled: [
        type: :boolean,
        required: true,
        doc: "false to pause the schedule, true to resume it"
      ]
    ]

  alias Dobby.Schedules

  @impl true
  def on_before_validate_params(params), do: {:ok, Schedules.coerce_id_param(params)}

  @impl true
  def run(%{id: id, enabled: enabled}, _context) do
    case Schedules.set_enabled(id, enabled) do
      {:ok, schedule} -> {:ok, Schedules.describe(schedule)}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, Schedules.error_message(changeset)}
      {:error, reason} -> {:error, reason}
    end
  end
end
