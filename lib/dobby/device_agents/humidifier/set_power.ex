defmodule Dobby.DeviceAgents.Humidifier.SetPower do
  @moduledoc "Keeps the humidifier signal route on the shared HA humidity contract."
  use Jido.Action,
    name: "humidifier_set_power",
    description: "SetPower for a household humidifier",
    schema: [
      power: [type: {:in, [:on, :off]}, required: true],
      ref: [type: :string, required: true]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Humidity.set_power(params, context.state)
end
