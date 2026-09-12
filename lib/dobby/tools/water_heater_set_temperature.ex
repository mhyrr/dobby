defmodule Dobby.Tools.WaterHeaterSetTemperature do
  @moduledoc "Transport only; the water heater owns authorization and unit conversion."
  use Jido.Action,
    name: "water_heater_set_temperature",
    description:
      "Set a water heater target in Fahrenheit. Returns acceptance, not a measured temperature.",
    schema: [
      device: [type: :string, required: true, doc: "Water heater id from the roster."],
      temperature_f: [type: :float, required: true]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def on_before_validate_params(params),
    do: {:ok, Map.update(params, :temperature_f, nil, &number/1)}

  defp number(value) when is_integer(value), do: value * 1.0

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp number(value), do: value

  @impl true
  def run(%{device: device, temperature_f: value}, context),
    do:
      Dobby.Tools.Device.command(
        device,
        Dobby.DeviceAgents.WaterHeater,
        "water_heater.set_temperature",
        %{temperature_f: value},
        context,
        %{target_temperature_f: value}
      )
end
