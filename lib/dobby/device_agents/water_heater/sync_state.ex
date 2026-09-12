defmodule Dobby.DeviceAgents.WaterHeater.SyncState do
  @moduledoc """
  HA reports replace observations and capability knowledge together.

  HA state is the operation mode, not an indication that water is heating.
  A missing attribute erases prior knowledge because HA sends full state
  objects. Unavailable reports also erase readings, even if attributes linger.
  """
  use Jido.Action,
    name: "water_heater_sync_state",
    description: "Applies HA water heater observations",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgents.WaterHeater

  @keys [
    :available,
    :mode,
    :power,
    :away_mode,
    :temperature_unit,
    :current_temperature,
    :target_temperature,
    :current_temperature_f,
    :target_temperature_f,
    :capabilities
  ]

  @impl true
  def run(%{entity_id: entity_id}, %{state: %{entity_id: expected}}) when entity_id != expected,
    do: {:ok, %{}}

  def run(params, %{state: previous}) do
    available = params.state not in [nil, "unknown", "unavailable", ""]
    attrs = if available, do: params.attributes, else: %{}

    unit =
      if available,
        do: unit(Map.get(attrs, "unit_of_measurement", previous.settings[:temperature_unit]))

    modes = modes(attrs["operation_list"])
    mode = if available, do: params.state
    features = attrs["supported_features"]

    next = %{
      available: available,
      mode: mode,
      power: power(mode, modes),
      away_mode: away(attrs["away_mode"]),
      temperature_unit: unit,
      current_temperature: number(attrs["current_temperature"]),
      target_temperature: number(attrs["temperature"]),
      current_temperature_f: WaterHeater.to_f(attrs["current_temperature"], unit),
      target_temperature_f: WaterHeater.to_f(attrs["temperature"], unit),
      capabilities: %{
        supports_temperature: supports?(features, 1),
        supports_mode: supports?(features, 2),
        supports_away_mode: supports?(features, 4),
        supports_power: supports?(features, 8),
        modes: modes,
        min_temperature_f: WaterHeater.to_f(attrs["min_temp"], unit),
        max_temperature_f: WaterHeater.to_f(attrs["max_temp"], unit)
      }
    }

    case Dobby.DeviceAgent.changes(previous, next, @keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        snapshot = snapshot(Map.merge(previous, next))

        {:ok, next,
         [
           Dobby.DeviceEvents.emit(previous.dobby_id, snapshot,
             changed: changed,
             moved: moved,
             commanded?:
               command_changed?(previous.last_command, changed) and
                 WaterHeater.command_arrived?(previous.last_command, snapshot)
           )
         ]}
    end
  end

  defp command_changed?(%{action: :set_temperature}, changed),
    do: :target_temperature_f in changed

  defp command_changed?(%{action: :set_mode}, changed), do: :mode in changed
  defp command_changed?(%{action: :set_away_mode}, changed), do: :away_mode in changed
  defp command_changed?(%{action: :set_power}, changed), do: :power in changed
  defp command_changed?(_, _), do: false

  def snapshot(state) do
    {min, max} = WaterHeater.accepted_range(state)

    state
    |> Map.take(@keys)
    |> Map.merge(%{
      id: state.dobby_id,
      name: state.name,
      type: :water_heater,
      min_temperature_f: min,
      max_temperature_f: max
    })
  end

  defp unit(value) when value in ["°F", "°C", "K"], do: value
  defp unit(_), do: nil
  defp number(value) when is_number(value), do: value
  defp number(_), do: nil

  defp modes(value) when is_list(value),
    do: Enum.filter(value, &(is_binary(&1) and &1 not in ["", "unknown", "unavailable"]))

  defp modes(_), do: []
  defp power("off", _), do: :off
  defp power("on", _), do: :on
  defp power(mode, modes) when is_binary(mode), do: if(mode in modes, do: :on)
  defp power(_, _), do: nil
  defp away(value) when value in [true, "on"], do: true
  defp away(value) when value in [false, "off"], do: false
  defp away(_), do: nil

  defp supports?(features, flag) when is_integer(features) and features >= 0,
    do: Bitwise.band(features, flag) == flag

  defp supports?(_, _), do: nil
end
