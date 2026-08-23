defmodule Dobby.Tools.AccessCoverGetStatus do
  @moduledoc "Tool: read a household access cover from deterministic agent state."

  use Jido.Action,
    name: "access_cover_get_status",
    description: "Read whether a garage door, gate, door, or window is open or closed.",
    schema: [device: [type: :string, required: true, doc: "Access-cover id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.AccessCover

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, AccessCover, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        cover_state: state.cover_state,
        position: state.position
      }
    end)
  end
end
