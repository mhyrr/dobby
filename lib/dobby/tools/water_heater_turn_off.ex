defmodule Dobby.Tools.WaterHeaterTurnOff do
  @moduledoc "Transport only; the water heater owns authorization and unit conversion."
  use Jido.Action,
    name: "water_heater_turn_off",
    description: "Turn off a water heater if it advertises power control. Returns acceptance.",
    schema: [device: [type: :string, required: true, doc: "Water heater id from the roster."]]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device}, context),
    do:
      Dobby.Tools.Device.command(
        device,
        Dobby.DeviceAgents.WaterHeater,
        "water_heater.set_power",
        %{power: :off},
        context
      )
end
