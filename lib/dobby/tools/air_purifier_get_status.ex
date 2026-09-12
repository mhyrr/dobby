defmodule Dobby.Tools.AirPurifierGetStatus do
  @moduledoc "Tool: read a household air purifier from deterministic agent state."

  use Jido.Action,
    name: "air_purifier_get_status",
    description:
      "Read a air purifier's power, speed, capabilities and bound filter readings; missing values are unknown.",
    schema: [device: [type: :string, required: true, doc: "Air purifier id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.AirPurifier

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, AirPurifier, &AirPurifier.snapshot/1)
  end
end
