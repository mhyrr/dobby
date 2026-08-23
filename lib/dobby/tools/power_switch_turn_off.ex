defmodule Dobby.Tools.PowerSwitchTurnOff do
  @moduledoc "Tool: turn off a household switch."

  use Jido.Action,
    name: "power_switch_turn_off",
    description: "Turn off a household switch. Returns command acceptance.",
    schema: [device: [type: :string, required: true, doc: "Switch id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.PowerSwitch

  @impl Dobby.Tools
  def label(arguments), do: "turning off the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do:
      Dobby.Tools.Device.command(device_id, PowerSwitch, "power_switch.set_power", %{power: :off})
end
