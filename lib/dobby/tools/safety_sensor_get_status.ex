defmodule Dobby.Tools.SafetySensorGetStatus do
  @moduledoc "Tool: read a household safety sensor from deterministic agent state."

  use Jido.Action,
    name: "safety_sensor_get_status",
    description:
      "Read whether a smoke, carbon monoxide, gas, water, heat, or cold alarm is active.",
    schema: [device: [type: :string, required: true, doc: "Safety-sensor id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.SafetySensor

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, SafetySensor, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        alarm: state.alarm,
        hazard: state.hazard
      }
    end)
  end
end
