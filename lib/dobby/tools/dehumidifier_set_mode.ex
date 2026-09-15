defmodule Dobby.Tools.DehumidifierSetMode do
  @moduledoc "Tool transport for the dehumidifier; the device agent validates every command."
  use Jido.Action,
    name: "dehumidifier_set_mode",
    description:
      "SetMode for a household dehumidifier. Returns command acceptance, not observed state.",
    schema: [
      device: [type: :string, required: true, doc: "Dehumidifier id from the roster."],
      mode: [type: :string, required: true, doc: "An exact available_modes value from status."]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id, mode: mode}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        Dobby.DeviceAgents.Dehumidifier,
        "dehumidifier.set_mode",
        %{mode: mode},
        context
      )
end
