defmodule Dobby.Tools.IceMakerGetStatus do
  @moduledoc "Reads appliance observations through the same roster boundary as every device tool."

  use Jido.Action,
    name: "ice_maker_get_status",
    description:
      "Reports ice maker activity, bin-full state, water-empty state, and cleaning needs. Read-only; null means unknown. A bin that is not full does not prove ice is available.",
    schema: [device: [type: :string, required: true, doc: "Device id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.IceMaker

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, IceMaker, fn state ->
      IceMaker.snapshot(state)
      |> Map.delete(:id)
      |> Map.put(:device, state.dobby_id)
    end)
  end
end
