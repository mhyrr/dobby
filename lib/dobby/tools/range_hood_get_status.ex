defmodule Dobby.Tools.RangeHoodGetStatus do
  @moduledoc "Tool: read a household range hood from deterministic agent state."

  use Jido.Action,
    name: "range_hood_get_status",
    description:
      "Read a range hood's power, speed, capabilities and bound filter readings; missing values are unknown.",
    schema: [device: [type: :string, required: true, doc: "Range hood id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.RangeHood

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, RangeHood, fn state ->
      RangeHood.snapshot(state)
      |> Map.delete(:id)
      |> Map.put(:device, state.dobby_id)
    end)
  end
end
