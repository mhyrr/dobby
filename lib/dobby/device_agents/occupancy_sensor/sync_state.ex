defmodule Dobby.DeviceAgents.OccupancySensor.SyncState do
  @moduledoc """
  Translates an inbound HA `state_changed` into occupancy.

  `"on"` means detected across all three presence classes — HA's convention,
  decoded here into `occupied` so nothing above this boundary reasons about
  wire values. Anything else reads as `nil`: a sensor that has not spoken is
  not an empty room, and `changes/3` keeps that first report out of the
  moved calculus for the same reason.
  """

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
