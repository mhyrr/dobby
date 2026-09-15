defmodule Dobby.Tools.AirPurifierTurnOn do
  @moduledoc "Tool: turn on a household air purifier."

  use Jido.Action,
    name: "air_purifier_turn_on",
    description: "Turn on a household air purifier. Returns command acceptance.",
    schema: [device: [type: :string, required: true, doc: "Air purifier id from the roster."]]

  @behaviour Dobby.Tools
  alias Dobby.DeviceAgents.AirPurifier

  @impl Dobby.Tools
  def label(arguments), do: "turning on the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        AirPurifier,
        "air_purifier.set_power",
        %{power: :on},
        context
      )
end
