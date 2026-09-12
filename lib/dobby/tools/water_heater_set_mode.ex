defmodule Dobby.Tools.WaterHeaterSetMode do
  @moduledoc "Transport only; the water heater owns authorization and unit conversion."
  use Jido.Action,
    name: "water_heater_set_mode",
    description:
      "Set one exact mode from water heater status capabilities.modes. Returns acceptance.",
    schema: [
      device: [type: :string, required: true, doc: "Water heater id from the roster."],
      mode: [type: :string, required: true]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device, mode: value}, context),
    do:
      Dobby.Tools.Device.command(
        device,
        Dobby.DeviceAgents.WaterHeater,
        "water_heater.set_mode",
        %{mode: value},
        context
      )
end
