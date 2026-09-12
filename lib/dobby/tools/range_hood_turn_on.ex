defmodule Dobby.Tools.RangeHoodTurnOn do
  @moduledoc "Tool: turn on a household range hood."

  use Jido.Action,
    name: "range_hood_turn_on",
    description: "Turn on a household range hood. Returns command acceptance.",
    schema: [device: [type: :string, required: true, doc: "Range hood id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.RangeHood

  @impl Dobby.Tools
  def label(arguments), do: "turning on the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        RangeHood,
        "range_hood.set_power",
        %{power: :on},
        context
      )
end
