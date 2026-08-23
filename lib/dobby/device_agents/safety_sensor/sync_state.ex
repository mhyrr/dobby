defmodule Dobby.DeviceAgents.SafetySensor.SyncState do
  @moduledoc "Translates a Home Assistant safety detector into an alarm snapshot."

  use Jido.Action,
    name: "safety_sensor_sync_state",
    description: "Applies a Home Assistant state change to a safety sensor",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents

  @hazards %{
    "smoke" => :smoke,
    "carbon_monoxide" => :carbon_monoxide,
    "gas" => :gas,
    "moisture" => :water,
    "heat" => :heat,
    "cold" => :cold
  }

  @impl true
  def run(params, context) do
    previous = context.state

    next = %{
      available: available?(params.state),
      alarm: binary_state(params.state),
      hazard: Map.get(@hazards, params.attributes["device_class"])
    }

    keys = [:available, :alarm, :hazard]

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
      type: :safety_sensor,
      available: next.available,
      alarm: next.alarm,
      hazard: next.hazard
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]
  defp binary_state("on"), do: true
  defp binary_state("off"), do: false
  defp binary_state(_state), do: nil
end
