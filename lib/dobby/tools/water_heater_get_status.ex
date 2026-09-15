defmodule Dobby.Tools.WaterHeaterGetStatus do
  @moduledoc "Reads water heater observations with explicit units and advertised controls."
  use Jido.Action,
    name: "water_heater_get_status",
    description:
      "Read a water heater's measured and target temperatures, units, mode, away mode, power and capabilities. Mode is not proof that water is hot.",
    schema: [device: [type: :string, required: true, doc: "Water heater id from the roster."]]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"
  @impl true
  def run(%{device: device}, _context) do
    Dobby.Tools.Device.status(device, Dobby.DeviceAgents.WaterHeater, fn state ->
      state
      |> Dobby.DeviceAgents.WaterHeater.snapshot()
      |> Map.delete(:id)
      |> Map.put(:device, state.dobby_id)
    end)
  end
end
