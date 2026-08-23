defmodule Dobby.DeviceAgents.ContactSensor.SyncState do
  @moduledoc "Translates a Home Assistant contact entity into open or closed."

  use Jido.Action,
    name: "contact_sensor_sync_state",
    description: "Applies a Home Assistant state change to a contact sensor",
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
    next = %{available: available?(params.state), open: binary_state(params.state)}
    keys = [:available, :open]

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
      type: :contact_sensor,
      available: next.available,
      open: next.open
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]
  defp binary_state("on"), do: true
  defp binary_state("off"), do: false
  defp binary_state(_state), do: nil
end
