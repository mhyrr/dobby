defmodule Dobby.Tools.HumidifierSetHumidity do
  @moduledoc "Tool transport for the humidifier; the device agent validates every command."
  use Jido.Action,
    name: "humidifier_set_humidity",
    description:
      "SetHumidity for a household humidifier. Returns command acceptance, not observed state.",
    schema: [
      device: [type: :string, required: true, doc: "Humidifier id from the roster."],
      target_humidity_percent: [
        type: :integer,
        required: true,
        doc: "Whole humidity percent within the reported and household ranges."
      ]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def on_before_validate_params(params),
    do:
      {:ok,
       Map.update(
         params,
         :target_humidity_percent,
         nil,
         &Dobby.DeviceAgents.Humidity.normalize_target/1
       )}

  @impl true
  def run(%{device: device_id, target_humidity_percent: target}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        Dobby.DeviceAgents.Humidifier,
        "humidifier.set_humidity",
        %{target_humidity_percent: target},
        context
      )
end
