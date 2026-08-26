defmodule Dobby.DeviceAgents.EnvironmentMonitor.SyncState do
  @moduledoc "Collects environmental sensor entities into one monitor snapshot."

  use Jido.Action,
    name: "environment_monitor_sync_state",
    description: "Applies a Home Assistant sensor reading to an environment monitor",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceEvents

  @impl true
  def run(params, context) do
    previous = context.state

    case binding_for(previous.bindings, params.entity_id) do
      nil ->
        {:ok, %{}}

      binding ->
        reading = number(params.state)
        readings = Map.put(previous.readings, binding, reading)
        units = put_unit(previous.units, binding, params.attributes["unit_of_measurement"])

        next = %{
          available: Enum.any?(readings, fn {_key, value} -> is_number(value) end),
          readings: readings,
          units: units
        }

        # `DeviceAgent.changes/3` judges movement per state key, and this
        # device keeps many sensors inside one `readings` map — the second
        # sensor's first report would read as the map "moving" and the boot
        # sequence would land in the log. The unit of arrival is the single
        # reading this sync touches, so movement is judged on that cell.
        cells = [
          available: {previous.available, next.available},
          readings: {Map.get(previous.readings, binding), reading},
          units: {Map.get(previous.units, binding), Map.get(units, binding)}
        ]

        changed = for {key, {before, now}} <- cells, before != now, do: key
        moved = for {key, {before, now}} <- cells, before != now and not is_nil(before), do: key

        case changed do
          [] ->
            {:ok, next}

          changed ->
            merged = Map.merge(previous, next)

            {:ok, next,
             [
               DeviceEvents.emit(previous.dobby_id, snapshot(merged),
                 changed: changed,
                 moved: moved
               )
             ]}
        end
    end
  end

  @spec snapshot(map()) :: map()
  def snapshot(state) do
    %{
      id: state.dobby_id,
      name: state.name,
      type: :environment_monitor,
      available: state.available,
      readings: state.readings,
      units: state.units
    }
  end

  defp binding_for(bindings, entity_id) do
    Enum.find_value(bindings, fn {binding, bound_entity_id} ->
      if bound_entity_id == entity_id, do: binding
    end)
  end

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _not_number -> nil
    end
  end

  defp number(value) when is_number(value), do: value / 1
  defp number(_value), do: nil

  defp put_unit(units, binding, unit) when is_binary(unit), do: Map.put(units, binding, unit)
  defp put_unit(units, _binding, _unit), do: units
end
