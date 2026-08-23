defmodule Dobby.Tools.FanSetSpeed do
  @moduledoc "Tool: set a household fan's speed."

  use Jido.Action,
    name: "fan_set_speed",
    description: "Set fan speed from 1 to 100 percent when the fan supports it.",
    schema: [
      device: [type: :string, required: true, doc: "Fan id from the roster."],
      speed_percent: [type: :integer, required: true, doc: "Speed from 1 to 100 percent."]
    ]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.Fan

  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id, speed_percent: percent}, _context),
    do: Dobby.Tools.Device.command(device_id, Fan, "fan.set_speed", %{speed_percent: percent})
end
