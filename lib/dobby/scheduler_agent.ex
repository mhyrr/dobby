defmodule Dobby.SchedulerAgent do
  @moduledoc """
  The household's timer (design §9).

  Deterministic all the way down. It holds no conversation, has no tools, and
  never reaches a model: at boot it reads the enabled schedule rows and asks
  Jido to register one cron job each, and when a job ticks it reads the row and
  dispatches the stored device action down the same typed path a tool uses.
  The rig asserts the shape of that directly — a firing trace contains zero
  model calls.

  It runs on the default `Direct` strategy, the same as the device agents.
  Nothing here needs a state machine; a schedule fires or it does not.

  ## The timers are compared against the rows, never against memory

  This agent deliberately keeps no record of what it registered. Two reasons,
  and the second one cost an afternoon.

  The rows are the truth, so "which schedule has no timer?" should be asked of
  the rows and the live jobs — not of a note this agent wrote to itself, which
  can only ever be a third thing to get out of sync.

  And it could not keep that note correctly anyway. Jido merges an action's
  state update into agent state with a *deep* merge, so a map field cannot be
  cleared or pruned by assigning it: returning `%{registered: %{}}` leaves the
  old contents exactly where they were. A deleted schedule would have stayed in
  that map forever, and `unregistered/0` would have reported a phantom missing
  timer for every schedule ever removed. The barrier below is what caught it.

  ## Registration is eventual, and that is checked

  `Jido.AgentServer` executes directives from a drain loop it kicks off with
  `send(self(), :drain)`, so the `Cron` directives an action returns are still
  queued when the call that produced them replies. Worse, `Cron` swallows a
  failed registration by design (`on_failure: :keep`) and only logs it — which
  would make a schedule that never fires look exactly like one that does. So
  `sync/0` waits for the jobs to match the rows, and `unregistered/0` reports
  any that never appeared.
  """

  @id "scheduler"

  use Jido.Agent,
    name: "scheduler",
    description: "Fires household schedules on their cron specs, with no model involved",
    signal_routes: [
      {"dobby.schedule.sync", Dobby.SchedulerAgent.Sync},
      {"dobby.schedule.fire", Dobby.SchedulerAgent.Fire}
    ],
    schema: [
      last_fired: [type: {:or, [:map, nil]}, default: nil]
    ]

  alias Dobby.Schedules

  require Logger

  @doc """
  The registry ID the scheduler runs under.
  """
  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Rebuilds every timer from the enabled rows, and waits until they are running.

  Called at boot and after any write in `Dobby.Schedules`. Idempotent: the
  whole enabled set is re-registered each time, because a timer for a row that
  no longer says what it said is the bug incremental registration invites.
  """
  @spec sync(timeout()) :: :ok | {:error, term()}
  def sync(timeout \\ 2_000), do: settle(true, timeout)

  @doc """
  Cancels every timer without touching a row.

  Called on the way down by `Dobby.Home`. A cron job is owned by this agent and
  would die with it regardless, but it dies exiting `{:owner_down, :shutdown}`,
  which OTP reports as a crash. Taking the timers down deliberately keeps that
  report for the cases that deserve one.
  """
  @spec clear(timeout()) :: :ok | {:error, term()}
  def clear(timeout \\ 2_000), do: settle(false, timeout)

  @doc """
  The schedules that should have a timer and do not, with the reason to hand.

  Empty is the healthy answer. A non-empty result means a row was accepted at
  authoring time and rejected by the timer — the seam `Dobby.Schedules.Cron`
  documents — or that this agent restarted without a sync.
  """
  @spec unregistered() :: [map()]
  def unregistered do
    case server() do
      {:ok, pid} ->
        running = running_jobs(pid)

        for schedule <- wanted(),
            Schedules.job_id(schedule) not in running,
            do: %{schedule_id: schedule.id, label: schedule.label, cron: schedule.cron}

      {:error, _reason} ->
        []
    end
  end

  # The schedules that ought to have a timer right now: enabled, and still able
  # to reach the device they name.
  defp wanted, do: Enum.filter(Schedules.enabled(), &Schedules.runnable?/1)

  defp running_jobs(pid) do
    {:ok, server_state} = Jido.AgentServer.state(pid)
    Map.keys(server_state.cron_jobs)
  end

  defp settle(register?, timeout) do
    with {:ok, pid} <- server() do
      # Reality is read here, by the caller, and handed to the action. The
      # action can see agent state but not the server's live job table, and
      # cancelling a job requires knowing which ones are actually running.
      signal =
        Jido.Signal.new!("dobby.schedule.sync", %{
          register: register?,
          running: running_jobs(pid)
        })

      with {:ok, _agent} <- Jido.AgentServer.call(pid, signal) do
        await_settled(pid, register?, timeout)
      end
    end
  end

  defp await_settled(pid, register?, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_settled(pid, register?, deadline)
  end

  defp do_await_settled(pid, register?, deadline) do
    desired = if register?, do: MapSet.new(wanted(), &Schedules.job_id/1), else: MapSet.new()
    running = pid |> running_jobs() |> MapSet.new()

    cond do
      MapSet.equal?(desired, running) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # Not a failure the caller can act on: the rows are written, and the
        # gap is reportable through `unregistered/0`. Returning an error here
        # would make a correct `create_schedule` look broken.
        Logger.error(
          "scheduler: timers never settled — missing #{inspect(MapSet.difference(desired, running))}, " <>
            "stale #{inspect(MapSet.difference(running, desired))}"
        )

        :ok

      true ->
        Process.sleep(10)
        do_await_settled(pid, register?, deadline)
    end
  end

  defp server do
    case Dobby.Jido.whereis(@id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :scheduler_not_running}
    end
  end
end
