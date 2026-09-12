defmodule Dobby.Tools.HumidifierGetStatus do
  @moduledoc "Tool transport for the humidifier; the device agent validates every command."
  use Jido.Action,
    name: "humidifier_get_status",
    description:
      "Read humidifier humidity, power, action, mode, and capabilities. Percentages are relative humidity.",
    schema: [device: [type: :string, required: true, doc: "Humidifier id from the roster."]]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do:
      Dobby.Tools.Device.status(device_id, Dobby.DeviceAgents.Humidifier, fn state ->
        state |> Dobby.DeviceAgents.Humidifier.snapshot() |> Map.put(:device, state.dobby_id)
      end)
end
