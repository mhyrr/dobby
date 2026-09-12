defmodule Dobby.Tools.RangeHoodSetSpeed do
  @moduledoc "Tool: set a household range hood's speed."

  use Jido.Action,
    name: "range_hood_set_speed",
    description:
      "Set range hood speed from 1 to 100 percent when the fan supports it. " <>
        "Returns command acceptance, not the fan's observed speed.",
    schema: [
      device: [type: :string, required: true, doc: "Range hood id from the roster."],
      speed_percent: [type: :integer, required: true, doc: "Speed from 1 to 100 percent."]
    ]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.RangeHood

  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def on_before_validate_params(params),
    do: {:ok, Map.update(params, :speed_percent, nil, &Dobby.Tools.to_percent/1)}

  @impl true
  def run(%{device: device_id, speed_percent: percent}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        RangeHood,
        "range_hood.set_speed",
        %{speed_percent: percent},
        context
      )
end
