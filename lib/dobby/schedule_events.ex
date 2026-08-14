defmodule Dobby.ScheduleEvents do
  @moduledoc """
  The `dobby.schedule.fired` seam.

  Every firing announces itself, whether it actuated the house or was refused.
  The thread renders it as a system line (design §10.1 — "· thermostat set to
  70 — schedule 'weeknight heat'") and the admin's activity log keeps the
  detail.

  It exists now, before either surface does, because a firing is otherwise the
  one thing in Dobby that happens with nobody watching. Telemetry records that
  it happened; this is what lets a test — or later, a person — establish that it
  happened *before* the service call it caused. Telemetry cannot order events
  across sources (§12), and a message can.
  """

  @topic "dobby:schedules"

  @doc """
  The PubSub topic carrying schedule firings.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the calling process to schedule firings.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Dobby.PubSub, @topic)

  @doc """
  Builds the emit directive announcing that a schedule fired.

  `outcome` is the honest one: `:accepted` when the device agent took the
  command, `{:rejected, reason}` when household policy or availability refused
  it, `{:error, reason}` when the schedule could not be dispatched at all.
  """
  @spec emit(Dobby.Schedules.Schedule.t(), term()) :: Jido.Agent.Directive.Emit.t()
  def emit(schedule, outcome) do
    signal =
      Jido.Signal.new!("dobby.schedule.fired", %{
        schedule_id: schedule.id,
        label: schedule.label,
        device: schedule.target,
        action: schedule.action,
        args: schedule.args,
        outcome: outcome
      })

    %Jido.Agent.Directive.Emit{
      signal: signal,
      dispatch: [{:pubsub, target: Dobby.PubSub, topic: @topic}]
    }
  end
end
