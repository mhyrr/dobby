defmodule Dobby.DeviceAgents.PowerSwitch.SyncState do
  @moduledoc "Translates Home Assistant switch state into power state."

  use Jido.Action,
    name: "power_switch_sync_state",
    description: "Applies a Home Assistant state change to a power switch",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents

  @impl true
  def run(params, context) do
    previous = context.state
    next = %{available: available?(params.state), power: power(params.state)}
    keys = [:available, :power]

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        commanded? = commanded?(previous, next)

        {:ok, spend(next, previous.last_command),
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved,
             commanded?: commanded?
           )
         ]}
    end
  end

  # The echo is one-shot, as the lock's is (Greg, 2026-11-16, TK-064). On and
  # off are two values, so a standing command read every hand that put the
  # switch back where Dobby had once sent it as Dobby's: half of all hands,
  # forever. The command is spent by the first report it is judged against,
  # whether that report is its echo or a hand, so a command to a switch that
  # was already there, which Home Assistant never echoes, is spent by the next
  # hand instead of swallowing it. A switch that goes quiet has not answered
  # either way, so the command outlives that.
  defp spend(%{available: true} = next, %{result: :accepted}),
    do: Map.put(next, :last_command, nil)

  defp spend(next, _command), do: next

  @spec snapshot(map()) :: map()
  def snapshot(state), do: snapshot(state, state)

  defp snapshot(previous, next) do
    %{
      id: previous.dobby_id,
      name: previous.name,
      type: :power_switch,
      available: next.available,
      power: next.power
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]
  defp power("on"), do: :on
  defp power("off"), do: :off
  defp power(_state), do: nil

  defp commanded?(%{last_command: %{result: :accepted, power: power}}, next),
    do: next.power == power

  defp commanded?(_previous, _next), do: false
end
