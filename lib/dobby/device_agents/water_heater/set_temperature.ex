defmodule Dobby.DeviceAgents.WaterHeater.SetTemperature do
  @moduledoc """
  Intersects HA's temperature envelope with household bounds before conversion.

  Missing units or either range bound refuse the command. HA's optional step
  attribute is reported in an integration's native unit while state values are
  converted to the HA system unit; treating it as a step in the state unit
  would silently round the wrong quantity. HA retains step enforcement.
  """
  use Jido.Action,
    name: "water_heater_set_temperature",
    description: "Validates a water heater target and emits HA's temperature call",
    schema: [
      temperature_f: [type: {:or, [:integer, :float]}, required: true],
      ref: [type: :string, required: true]
    ]

  alias Dobby.DeviceAgents.WaterHeater
  alias WaterHeater.Command

  @impl true
  def run(%{temperature_f: temperature, ref: ref}, %{state: state}) do
    with :ok <- Command.authorize(state, :supports_temperature),
         :ok <- authorize_temperature(state, temperature) do
      Command.accept(
        state,
        ref,
        :set_temperature,
        %{temperature_f: temperature},
        "set_temperature",
        %{temperature: WaterHeater.from_f(temperature, state.temperature_unit)}
      )
    else
      {:error, reason} -> Command.reject(ref, :set_temperature, reason)
    end
  end

  defp authorize_temperature(state, temperature) do
    {min, max} = WaterHeater.accepted_range(state)

    cond do
      state.temperature_unit not in ["°F", "°C", "K"] ->
        {:error,
         "water heater temperature unit is unknown; configure temperature_unit to match Home Assistant"}

      not is_number(min) or not is_number(max) or min > max ->
        {:error, "water heater temperature range is unknown or invalid"}

      temperature < min ->
        {:error, "target is below the household minimum of #{min}°F"}

      temperature > max ->
        {:error, "target is above the household maximum of #{max}°F"}

      true ->
        :ok
    end
  end
end
