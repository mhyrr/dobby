defmodule Dobby.Tools.DishwasherGetStatus do
  @moduledoc "Reads appliance observations through the same roster boundary as every device tool."

  use Jido.Action,
    name: "dishwasher_get_status",
    description:
      "Reports the dishwasher cycle, door, and remote readiness. Read-only; null means unknown. Temperatures include units; targets are not measured temperatures.",
    schema: [device: [type: :string, required: true, doc: "Device id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Dishwasher

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Dishwasher, fn state ->
      Dishwasher.snapshot(state)
      |> Map.delete(:id)
      |> Map.put(:device, state.dobby_id)
    end)
  end
end
