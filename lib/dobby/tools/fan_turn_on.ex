defmodule Dobby.Tools.FanTurnOn do
  @moduledoc "Tool: turn on a household fan."

  use Jido.Action,
    name: "fan_turn_on",
    description: "Turn on a household fan. Returns command acceptance.",
    schema: [device: [type: :string, required: true, doc: "Fan id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.Fan

  @impl Dobby.Tools
  def label(arguments), do: "turning on the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do: Dobby.Tools.Device.command(device_id, Fan, "fan.set_power", %{power: :on})
end
