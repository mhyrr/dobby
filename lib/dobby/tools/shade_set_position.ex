defmodule Dobby.Tools.ShadeSetPosition do
  @moduledoc "Tool: set a household shade's position."

  use Jido.Action,
    name: "shade_set_position",
    description: "Set a shade from 0 percent closed to 100 percent open when supported.",
    schema: [
      device: [type: :string, required: true, doc: "Shade id from the roster."],
      position: [type: :integer, required: true, doc: "Position from 0 to 100 percent open."]
    ]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.Shade

  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id, position: position}, _context),
    do: Dobby.Tools.Device.command(device_id, Shade, "shade.set_position", %{position: position})
end
