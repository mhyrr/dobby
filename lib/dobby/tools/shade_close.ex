defmodule Dobby.Tools.ShadeClose do
  @moduledoc "Tool: close a household shade."

  use Jido.Action,
    name: "shade_close",
    description: "Close a household blind, shade, curtain, shutter, or awning.",
    schema: [device: [type: :string, required: true, doc: "Shade id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.Shade

  @impl Dobby.Tools
  def label(arguments), do: "closing the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        Shade,
        "shade.move",
        %{movement: :close},
        %{shade_state: :closed}
      )
end
