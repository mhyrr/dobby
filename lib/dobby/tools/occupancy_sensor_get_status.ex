defmodule Dobby.Tools.OccupancySensorGetStatus do
  @moduledoc "Tool: read occupancy from deterministic agent state."

  use Jido.Action,
    name: "occupancy_sensor_get_status",
    description: "Read whether a household area reports motion, occupancy, or presence.",
    schema: [device: [type: :string, required: true, doc: "Occupancy-sensor id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.OccupancySensor

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, OccupancySensor, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        occupied: state.occupied
      }
    end)
  end
end
