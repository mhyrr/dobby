defmodule Dobby.Tools.AirPurifierSetSpeed do
  @moduledoc "Tool: set a household air purifier's speed."

  use Jido.Action,
    name: "air_purifier_set_speed",
    description:
      "Set air purifier speed from 1 to 100 percent when the fan supports it. " <>
        "Returns command acceptance, not the fan's observed speed.",
    schema: [
      device: [type: :string, required: true, doc: "Air purifier id from the roster."],
      speed_percent: [type: :integer, required: true, doc: "Speed from 1 to 100 percent."]
    ]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.AirPurifier

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
        AirPurifier,
        "air_purifier.set_speed",
        %{speed_percent: percent},
        context
      )
end
