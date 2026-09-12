defmodule Dobby.Tools.HumidifierTurnOn do
  @moduledoc "Tool transport for the humidifier; the device agent validates every command."
  use Jido.Action,
    name: "humidifier_turn_on",
    description:
      "TurnOn for a household humidifier. Returns command acceptance, not observed state.",
    schema: [device: [type: :string, required: true, doc: "Humidifier id from the roster."]]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "turning on the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        Dobby.DeviceAgents.Humidifier,
        "humidifier.set_power",
        %{power: :on},
        context
      )
end
