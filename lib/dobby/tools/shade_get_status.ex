defmodule Dobby.Tools.ShadeGetStatus do
  @moduledoc "Tool: read a household shade from deterministic agent state."

  use Jido.Action,
    name: "shade_get_status",
    description: "Read a household shade's state, position, and capabilities.",
    schema: [device: [type: :string, required: true, doc: "Shade id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.Shade

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Shade, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        shade_state: state.shade_state,
        position: state.position,
        supports_position: state.supports_position
      }
    end)
  end
end
