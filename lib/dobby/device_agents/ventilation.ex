defmodule Dobby.DeviceAgents.Ventilation do
  @moduledoc """
  The native fan interface shared by air purifiers and range hoods.

  These household jobs share HA's fan services, not a vendor API. Optional
  filter readings remain independent: a working filter sensor cannot authorize
  a command to an unavailable fan. Explicit bindings establish the job because
  HA's fan domain does not reliably distinguish a hood from a purifier.
  """
  alias Dobby.DeviceAgents.{ApplianceReadings, Fan, Validation}
  alias Dobby.{DeviceAgent, DeviceEvents}

  def validate_device(device, readings) do
    with :ok <- Validation.device(device, [:fan], Keyword.keys(readings)) do
      cond do
        not Regex.match?(~r/^fan\.[a-z0-9_]+$/, device.bindings.fan) ->
          {:error, "bindings.fan must name a fan entity"}

        Enum.uniq(Map.values(device.bindings)) != Map.values(device.bindings) ->
          {:error, "each reading must bind a different entity"}

        map_size(device.bindings) == 1 ->
          :ok

        true ->
          ApplianceReadings.validate_device(
            %{device | bindings: Map.delete(device.bindings, :fan)},
            readings
          )
      end
    end
  end

  def initial_state(device) do
    device
    |> DeviceAgent.initial_state(:fan)
    |> Map.put(:bindings, device.bindings)
    |> Map.put(
      :readings,
      Map.new(Map.delete(device.bindings, :fan), fn {key, _} -> {key, nil} end)
    )
  end

  def snapshot(state, type) do
    state
    |> Fan.SyncState.snapshot()
    |> Map.put(:type, type)
    |> Map.merge(%{readings: state.readings, units: state.units})
  end

  def sync(%{entity_id: id} = params, %{entity_id: id} = previous, _readings, type) do
    # Unknown fan states cannot retain stale percentages or authorize writes.
    available = params.state in ["on", "off"]

    decoded =
      Fan.SyncState.decode(%{
        params
        | attributes: if(available, do: params.attributes, else: %{})
      })

    next = %{decoded | available: available}
    %{changed: changed, moved: moved} = DeviceAgent.changes(previous, next, Map.keys(next))
    observed = snapshot(Map.merge(previous, next), type)

    commanded =
      available and command_changed?(previous.last_command, changed) and
        Fan.command_arrived?(previous.last_command, observed)

    emit(previous, next, type, changed, moved, commanded)
  end

  def sync(params, previous, reading_types, type) do
    binding =
      Enum.find_value(previous.bindings, fn {key, id} -> if id == params.entity_id, do: key end)

    if binding do
      {value, unit} =
        ApplianceReadings.decode_reading(Keyword.fetch!(reading_types, binding), params)

      units =
        if unit,
          do: Map.put(previous.units, binding, unit),
          else: Map.delete(previous.units, binding)

      next = %{readings: Map.put(previous.readings, binding, value), units: units}

      cells = [
        readings: {previous.readings[binding], value},
        units: {previous.units[binding], unit}
      ]

      changed = for {key, {old, new}} <- cells, old != new, do: key
      moved = for {key, {old, new}} <- cells, old != new and not is_nil(old), do: key
      emit(previous, next, type, changed, moved, false)
    else
      {:ok, %{}}
    end
  end

  defp command_changed?(%{action: :set_power}, changed), do: :power in changed
  defp command_changed?(%{action: :set_speed}, changed), do: :speed_percent in changed
  defp command_changed?(_, _), do: false

  defp emit(_previous, next, _type, [], _moved, _commanded), do: {:ok, next}

  defp emit(previous, next, type, changed, moved, commanded) do
    {:ok, next,
     [
       DeviceEvents.emit(previous.dobby_id, snapshot(Map.merge(previous, next), type),
         changed: changed,
         moved: moved,
         commanded?: commanded
       )
     ]}
  end
end
