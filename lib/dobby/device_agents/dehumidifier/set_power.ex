defmodule Dobby.DeviceAgents.Dehumidifier.SetPower do
  @moduledoc "Keeps the dehumidifier signal route on the shared HA humidity contract."
  use Jido.Action,
    name: "dehumidifier_set_power",
    description: "SetPower for a household dehumidifier",
    schema: [
      power: [type: {:in, [:on, :off]}, required: true],
      ref: [type: :string, required: true]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Humidity.set_power(params, context.state)
end
