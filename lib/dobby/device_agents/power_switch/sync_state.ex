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
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved,
             commanded?: commanded?(previous, next)
           )
         ]}
    end
  end

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
