defmodule Dobby.Tools.FanGetStatus do
  @moduledoc "Tool: read a household fan from deterministic agent state."

  use Jido.Action,
    name: "fan_get_status",
    description: "Read a fan's power, speed, and speed-control capability.",
    schema: [device: [type: :string, required: true, doc: "Fan id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.Fan

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Fan, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        power: state.power,
        speed_percent: state.speed_percent,
        supports_speed: state.supports_speed
      }
    end)
  end
end
