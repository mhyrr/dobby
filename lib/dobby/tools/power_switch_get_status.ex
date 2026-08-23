defmodule Dobby.Tools.PowerSwitchGetStatus do
  @moduledoc "Tool: read a household switch from deterministic agent state."

  use Jido.Action,
    name: "power_switch_get_status",
    description: "Read whether a household switch is on or off.",
    schema: [device: [type: :string, required: true, doc: "Switch id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.PowerSwitch

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, PowerSwitch, fn state ->
      %{device: state.dobby_id, name: state.name, available: state.available, power: state.power}
    end)
  end
end
