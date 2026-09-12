defmodule Dobby.DeviceAgents.ApplianceReadings do
  @moduledoc """
  The sensor transport shared by the appliance types.

  Types declare which readings mean something to them. This module only
  validates bindings and decodes HA's scalar wire values. It has no device
  registry, vendor dispatch, command route, or network access.

  Availability means at least one bound reading is known. Every other reading
  retains its own null, so a working door sensor cannot make a missing freezer
  temperature look known. Movement is judged per cell, as for environment
  monitors; a second sensor's first report must not announce the boot sequence.
  """

  alias Dobby.DeviceEvents

  def validate_device(device, reading_types) do
    bindings = device.bindings

    with :ok <- Dobby.DeviceAgents.Validation.device(device, [], Keyword.keys(reading_types)) do
      cond do
        map_size(bindings) == 0 ->
          {:error, "an appliance needs at least one reading binding"}

        Enum.uniq(Map.values(bindings)) != Map.values(bindings) ->
          {:error, "each appliance reading must bind a different entity"}

        true ->
          validate_domains(bindings, reading_types)
      end
    end
  end

  def initial_state(device) do
    device
    |> Dobby.DeviceAgent.initial_state()
    |> Map.put(:readings, Map.new(device.bindings, fn {key, _entity} -> {key, nil} end))
  end

  def snapshot(state, type) do
    %{
      id: state.dobby_id,
      name: state.name,
      type: type,
      available: state.available,
      readings: state.readings,
      units: state.units
    }
  end

  def sync(params, previous, reading_types, type) do
    binding =
      Enum.find_value(previous.bindings, fn {key, entity} ->
        if entity == params.entity_id, do: key
      end)

    if binding do
      {reading, unit} = decode(Keyword.fetch!(reading_types, binding), params)
      readings = Map.put(previous.readings, binding, reading)

      units =
        if unit,
          do: Map.put(previous.units, binding, unit),
          else: Map.delete(previous.units, binding)

      next = %{
        readings: readings,
        units: units,
        available: Enum.any?(readings, fn {_key, value} -> not is_nil(value) end)
      }

      cells = [
        available: {previous.available, next.available},
        readings: {previous.readings[binding], reading},
        units: {previous.units[binding], unit}
      ]

      changed = for {key, {before, now}} <- cells, before != now, do: key
      moved = for {key, {before, now}} <- cells, before != now and not is_nil(before), do: key

      if changed == [] do
        {:ok, next}
      else
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(Map.merge(previous, next), type),
             changed: changed,
             moved: moved
           )
         ]}
      end
    else
      {:ok, %{}}
    end
  end

  @doc false
  def decode_reading(type, params), do: decode(type, params)

  defp validate_domains(bindings, reading_types) do
    Enum.reduce_while(bindings, :ok, fn {key, entity_id}, :ok ->
      [domain | _] = String.split(entity_id, ".", parts: 2)
      domains = domains(Keyword.fetch!(reading_types, key))

      if domain in domains and Regex.match?(~r/^[a-z_]+\.[a-z0-9_]+$/, entity_id) do
        {:cont, :ok}
      else
        {:halt, {:error, "bindings.#{key} must name a #{Enum.join(domains, " or ")} entity"}}
      end
    end)
  end

  defp domains(:temperature), do: ["sensor", "number"]
  defp domains(:door), do: ["sensor", "binary_sensor"]
  defp domains(:boolean), do: ["binary_sensor"]
  defp domains(:text), do: ["sensor", "select"]
  defp domains(_type), do: ["sensor"]

  defp decode(_type, %{state: state}) when state in [nil, "unknown", "unavailable", ""],
    do: {nil, nil}

  defp decode(:temperature, %{state: state, attributes: attributes}) do
    unit = attributes["unit_of_measurement"]

    case {number(state), unit} do
      {value, unit} when is_number(value) and unit in ["°F", "°C", "K"] -> {value, unit}
      _unknown -> {nil, nil}
    end
  end

  defp decode(:percentage, %{state: state, attributes: attributes}) do
    case {number(state), attributes["unit_of_measurement"]} do
      {value, "%"} when is_number(value) and value >= 0 and value <= 100 -> {value, "%"}
      _unknown -> {nil, nil}
    end
  end

  defp decode(:duration, %{state: state, attributes: attributes}) do
    case {number(state), attributes["unit_of_measurement"]} do
      {value, unit} when is_number(value) and value >= 0 and unit in ["s", "min", "h"] ->
        {value, unit}

      _unknown ->
        {nil, nil}
    end
  end

  defp decode(:door, %{state: state}),
    do:
      {Map.get(
         %{"on" => true, "open" => true, "off" => false, "closed" => false, "locked" => false},
         state
       ), nil}

  defp decode(:boolean, %{state: state}),
    do: {Map.get(%{"on" => true, "off" => false}, state), nil}

  defp decode(:timestamp, %{state: state}) do
    case DateTime.from_iso8601(state) do
      {:ok, at, _offset} -> {DateTime.to_iso8601(at), nil}
      _invalid -> {nil, nil}
    end
  end

  defp decode(:text, %{state: state}), do: {state, nil}

  defp number(state) do
    case Float.parse(state) do
      {value, ""} -> value
      _invalid -> nil
    end
  end
end
