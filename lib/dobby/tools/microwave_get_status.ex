defmodule Dobby.Tools.MicrowaveGetStatus do
  @moduledoc "Reads appliance observations through the same roster boundary as every device tool."

  use Jido.Action,
    name: "microwave_get_status",
    description:
      "Reports microwave activity, door, remaining time with units, reported finish timestamp, and remote readiness. Read-only; null means unknown. Zero remaining time does not prove completion or permission to start.",
    schema: [device: [type: :string, required: true, doc: "Device id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Microwave

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Microwave, fn state ->
      Microwave.snapshot(state)
      |> Map.delete(:id)
      |> Map.put(:device, state.dobby_id)
    end)
  end
end
