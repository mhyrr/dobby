defmodule Dobby.DeviceAgents.Humidifier.SetHumidity do
  @moduledoc "Keeps the humidifier signal route on the shared HA humidity contract."
  use Jido.Action,
    name: "humidifier_set_humidity",
    description: "SetHumidity for a household humidifier",
    schema: [
      target_humidity_percent: [type: :integer, required: true],
      ref: [type: :string, required: true]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Humidity.set_humidity(params, context.state)
end
