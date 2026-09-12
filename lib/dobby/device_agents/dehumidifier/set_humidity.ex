defmodule Dobby.DeviceAgents.Dehumidifier.SetHumidity do
  @moduledoc "Keeps the dehumidifier signal route on the shared HA humidity contract."
  use Jido.Action,
    name: "dehumidifier_set_humidity",
    description: "SetHumidity for a household dehumidifier",
    schema: [
      target_humidity_percent: [type: :integer, required: true],
      ref: [type: :string, required: true]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Humidity.set_humidity(params, context.state)
end
