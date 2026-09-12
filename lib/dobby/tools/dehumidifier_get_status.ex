defmodule Dobby.Tools.DehumidifierGetStatus do
  @moduledoc "Tool transport for the dehumidifier; the device agent validates every command."
  use Jido.Action,
    name: "dehumidifier_get_status",
    description:
      "Read dehumidifier humidity, power, action, mode, and capabilities. Percentages are relative humidity.",
    schema: [device: [type: :string, required: true, doc: "Dehumidifier id from the roster."]]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do:
      Dobby.Tools.Device.status(device_id, Dobby.DeviceAgents.Dehumidifier, fn state ->
        state |> Dobby.DeviceAgents.Dehumidifier.snapshot() |> Map.put(:device, state.dobby_id)
      end)
end
