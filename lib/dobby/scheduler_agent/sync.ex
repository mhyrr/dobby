defmodule Dobby.SchedulerAgent.Sync do
  @moduledoc """
  Rebuilds every timer from the enabled schedule rows.

  The rows are the truth and the timers are a projection of them, so this
  re-registers the whole enabled set rather than reasoning about what changed.
  Jido's `Cron` directive upserts by `job_id`, which makes that cheap and
  removes the class of bug where a timer outlives the row that described it.

  `running` arrives in the signal rather than being read here: an action can
  see agent state but not `AgentServer`'s live job table, and cancelling
  requires knowing what is actually running. `register: false` cancels
  everything and registers nothing — the shutdown path.

  A schedule whose device left the manifest gets no timer. It stays in the
  table and `Dobby.Schedules.describe/2` reports why it cannot run — dropping
  the row would be destroying the household's intent because a config file
  changed, and registering it would mean discovering the problem at eight
  o'clock instead of now.
  """

  use Jido.Action,
    name: "scheduler_sync",
    description: "Registers a cron job per enabled schedule",
    schema: [
      register: [type: :boolean, default: true],
      running: [type: {:list, :any}, default: []]
    ]

  alias Dobby.Schedules
  alias Jido.Agent.Directive.{Cron, CronCancel}

  require Logger

  @impl true
  def run(%{register: register?, running: running}, _context) do
    schedules = if register?, do: registrable(), else: []
    desired = Enum.map(schedules, &Schedules.job_id/1)

    cancels =
      for job_id <- running, job_id not in desired, do: %CronCancel{job_id: job_id}

    crons =
      for schedule <- schedules do
        %Cron{
          job_id: Schedules.job_id(schedule),
          cron: schedule.cron,
          # The signal production sends, built by the one function that builds
          # it. A firing test casts the same thing.
          message: Schedules.fire_signal(schedule),
          # The household's timezone, from the manifest and stored per row — so
          # a schedule keeps meaning eight o'clock at home no matter where the
          # server thinks it is.
          timezone: schedule.timezone
        }
      end

    {:ok, %{}, cancels ++ crons}
  end

  defp registrable do
    {runnable, blocked} = Enum.split_with(Schedules.enabled(), &Schedules.runnable?/1)

    Enum.each(blocked, fn schedule ->
      Logger.warning(
        "schedule #{schedule.id} (#{schedule.label}) has no timer: #{Schedules.blocked_reason(schedule)}"
      )
    end)

    runnable
  end
end
