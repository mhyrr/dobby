defmodule Dobby.Tools.DoorbellGetStatus do
  @moduledoc "Tool: read a household doorbell from deterministic agent state."

  use Jido.Action,
    name: "doorbell_get_status",
    description: "Read a doorbell's last event, camera availability, and motion state.",
    schema: [device: [type: :string, required: true, doc: "Doorbell id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Doorbell

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Doorbell, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        last_event: state.last_event,
        last_event_at: state.last_event_at,
        camera_available: state.camera_available,
        motion: state.motion
      }
    end)
  end
end
