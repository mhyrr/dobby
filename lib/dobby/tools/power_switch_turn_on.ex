defmodule Dobby.Tools.PowerSwitchTurnOn do
  @moduledoc "Tool: turn on a household switch."

  use Jido.Action,
    name: "power_switch_turn_on",
    description: "Turn on a household switch. Returns command acceptance.",
    schema: [device: [type: :string, required: true, doc: "Switch id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.PowerSwitch

  @impl Dobby.Tools
  def label(arguments), do: "turning on the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        PowerSwitch,
        "power_switch.set_power",
        %{power: :on},
        context
      )
end
