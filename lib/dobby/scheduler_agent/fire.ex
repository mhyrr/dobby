defmodule Dobby.SchedulerAgent.Fire do
  @moduledoc """
  What happens at eight o'clock.

  A cron tick casts `dobby.schedule.fire` carrying an id and nothing else. This
  reads the row, dispatches the stored device action, and records what came
  back. No inference, no model, no template — the decision was made when the
  schedule was authored, and this is the part that was written down.

  The dispatch goes through `Dobby.Schedules.dispatch_signal/1`, which builds
  the same signal the model's tool builds. That is what makes household policy
  apply identically: an 85° schedule in a house capped at 76 is refused here
  exactly as it would be refused if someone asked out loud, and the refusal is
  announced rather than swallowed.

  A schedule can be paused, deleted, or blocked between the tick being set and
  the tick arriving. All three are ordinary and none of them are errors.
  """

  use Jido.Action,
    name: "scheduler_fire",
    description: "Dispatches one schedule's stored device action",
    schema: [schedule_id: [type: {:or, [:integer, :string]}, required: true]]

  alias Dobby.{DeviceAgent, ScheduleEvents, Schedules}

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
    case Schedules.dispatch_signal(schedule) do
      {:ok, pid, signal, ref} ->
        record(schedule, outcome(pid, signal, ref))

      {:error, reason} ->
        record(schedule, {:error, reason})
    end
  end

  defp outcome(pid, signal, ref) do
    case Jido.AgentServer.call(pid, signal) do
      {:ok, agent} -> DeviceAgent.command_outcome(agent.state, ref)
      {:error, reason} -> {:error, inspect(reason)}
    end
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
