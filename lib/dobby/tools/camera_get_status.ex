defmodule Dobby.Tools.CameraGetStatus do
  @moduledoc "Tool: read a household camera from deterministic agent state."

  use Jido.Action,
    name: "camera_get_status",
    description: "Read a camera's availability, activity, and related motion state.",
    schema: [device: [type: :string, required: true, doc: "Camera id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Camera

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Camera, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        activity: state.activity,
        motion: state.motion
      }
    end)
  end
end
