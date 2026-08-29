defmodule Dobby.Tools.FanTurnOff do
  @moduledoc "Tool: turn off a household fan."

  use Jido.Action,
    name: "fan_turn_off",
    description: "Turn off a household fan. Returns command acceptance.",
    schema: [device: [type: :string, required: true, doc: "Fan id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.Fan

  @impl Dobby.Tools
  def label(arguments), do: "turning off the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do: Dobby.Tools.Device.command(device_id, Fan, "fan.set_power", %{power: :off}, context)
end
