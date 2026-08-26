defmodule Dobby.Tools.ContactSensorGetStatus do
  @moduledoc "Tool: read a household contact sensor from deterministic agent state."

  use Jido.Action,
    name: "contact_sensor_get_status",
    description: "Read whether a door, window, or garage contact is open or closed.",
    schema: [device: [type: :string, required: true, doc: "Contact-sensor id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.ContactSensor

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, ContactSensor, fn state ->
      %{device: state.dobby_id, name: state.name, available: state.available, open: state.open}
    end)
  end
end
