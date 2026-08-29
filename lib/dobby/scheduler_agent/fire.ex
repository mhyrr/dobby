defmodule Dobby.SchedulerAgent.Fire do
  @moduledoc """
  What happens at eight o'clock.

  A cron tick casts `dobby.schedule.fire` carrying an id and nothing else. This
  reads the row, dispatches the stored device action, and records what came
  back. No inference, no model, no template — the decision was made when the
  schedule was authored, and this is the part that was written down.

  The dispatch goes through `Dobby.Schedules.dispatch_command/1`, which enters
  the same caller-aware protocol as a tool or card. That makes household policy
  apply identically and stops an old language-authored row from bypassing a
  device that later became hands only.

  A schedule can be paused, deleted, or blocked between the tick being set and
  the tick arriving. All three are ordinary and none of them are errors.
  """

  use Jido.Action,
    name: "scheduler_fire",
    description: "Dispatches one schedule's stored device action",
    schema: [schedule_id: [type: {:or, [:integer, :string]}, required: true]]

  alias Dobby.{ScheduleEvents, Schedules}

  require Logger

  @impl true
  def run(%{schedule_id: id}, _context) do
    case Schedules.fetch(id) do
      {:ok, %{enabled: true} = schedule} -> dispatch(schedule)
      {:ok, schedule} -> record(schedule, :paused)
      {:error, reason} -> vanished(id, reason)
    end
  end

  defp dispatch(schedule) do
    record(schedule, Schedules.dispatch_command(schedule))
  end

  # The row is gone — someone deleted the schedule between the timer being set
  # and it going off. There is nothing to announce and nobody to tell.
  defp vanished(id, reason) do
    Logger.info("schedule #{inspect(id)} fired but no longer exists: #{reason}")
    {:ok, %{last_fired: %{schedule_id: id, outcome: {:error, reason}, at: DateTime.utc_now()}}}
  end

  defp record(schedule, outcome) do
    # On the same telemetry spine as signals, tool calls, and HA calls, so the
    # rig sees a firing in the trace it already collects — and so the assertion
    # that matters, zero model calls, is made against the same source.
    :telemetry.execute(
      [:dobby, :schedule, :fired],
      %{system_time: System.system_time(:nanosecond)},
      %{schedule: schedule, outcome: outcome}
    )

    last_fired = %{
      schedule_id: schedule.id,
      label: schedule.label,
      outcome: outcome,
      at: DateTime.utc_now()
    }

    {:ok, %{last_fired: last_fired}, [ScheduleEvents.emit(schedule, outcome)]}
  end
end
