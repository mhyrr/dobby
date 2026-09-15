defmodule Dobby.Tools.RangeHoodTurnOff do
  @moduledoc "Tool: turn off a household range hood."

  use Jido.Action,
    name: "range_hood_turn_off",
    description: "Turn off a household range hood. Returns command acceptance.",
    schema: [device: [type: :string, required: true, doc: "Range hood id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.RangeHood

  @impl Dobby.Tools
  def label(arguments), do: "turning off the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        RangeHood,
        "range_hood.set_power",
        %{power: :off},
        context
      )
end
