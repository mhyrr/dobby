defmodule Dobby.DeviceAgents.OccupancySensor.SyncState do
  @moduledoc "Translates a Home Assistant motion or presence state into occupancy."

  use Jido.Action,
    name: "occupancy_sensor_sync_state",
    description: "Applies a Home Assistant state change to an occupancy sensor",
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
    next = %{available: available?(params.state), occupied: binary_state(params.state)}
    keys = [:available, :occupied]

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved
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
      type: :occupancy_sensor,
      available: next.available,
      occupied: next.occupied
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]
  defp binary_state("on"), do: true
  defp binary_state("off"), do: false
  defp binary_state(_state), do: nil
end
