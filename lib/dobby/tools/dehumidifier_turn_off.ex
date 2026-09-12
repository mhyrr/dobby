defmodule Dobby.Tools.DehumidifierTurnOff do
  @moduledoc "Tool transport for the dehumidifier; the device agent validates every command."
  use Jido.Action,
    name: "dehumidifier_turn_off",
    description:
      "TurnOff for a household dehumidifier. Returns command acceptance, not observed state.",
    schema: [device: [type: :string, required: true, doc: "Dehumidifier id from the roster."]]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "turning off the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        Dobby.DeviceAgents.Dehumidifier,
        "dehumidifier.set_power",
        %{power: :off},
        context
      )
end
