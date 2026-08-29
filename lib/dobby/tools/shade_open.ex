defmodule Dobby.Tools.ShadeOpen do
  @moduledoc "Tool: open a household shade."

  use Jido.Action,
    name: "shade_open",
    description: "Open a household blind, shade, curtain, shutter, or awning.",
    schema: [device: [type: :string, required: true, doc: "Shade id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.Shade

  @impl Dobby.Tools
  def label(arguments), do: "opening the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        Shade,
        "shade.move",
        %{movement: :open},
        context,
        %{shade_state: :open}
      )
end
