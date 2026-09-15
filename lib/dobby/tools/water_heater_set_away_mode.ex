defmodule Dobby.Tools.WaterHeaterSetAwayMode do
  @moduledoc "Transport only; the water heater owns authorization and unit conversion."
  use Jido.Action,
    name: "water_heater_set_away_mode",
    description:
      "Enable or disable the water heater away mode, if advertised. Returns acceptance.",
    schema: [
      device: [type: :string, required: true, doc: "Water heater id from the roster."],
      away_mode: [type: :boolean, required: true]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device, away_mode: value}, context),
    do:
      Dobby.Tools.Device.command(
        device,
        Dobby.DeviceAgents.WaterHeater,
        "water_heater.set_away_mode",
        %{away_mode: value},
        context
      )
end
