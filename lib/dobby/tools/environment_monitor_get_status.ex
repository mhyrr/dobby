defmodule Dobby.Tools.EnvironmentMonitorGetStatus do
  @moduledoc "Tool: read environmental measurements from deterministic agent state."

  use Jido.Action,
    name: "environment_monitor_get_status",
    description: "Read the measurements and units reported by an environmental monitor.",
    schema: [device: [type: :string, required: true, doc: "Monitor id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.EnvironmentMonitor

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, EnvironmentMonitor, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        readings: state.readings,
        units: state.units
      }
    end)
  end
end
