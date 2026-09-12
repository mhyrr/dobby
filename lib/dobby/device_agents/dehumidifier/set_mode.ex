defmodule Dobby.DeviceAgents.Dehumidifier.SetMode do
  @moduledoc "Keeps the dehumidifier signal route on the shared HA humidity contract."
  use Jido.Action,
    name: "dehumidifier_set_mode",
    description: "SetMode for a household dehumidifier",
    schema: [mode: [type: :string, required: true], ref: [type: :string, required: true]]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Humidity.set_mode(params, context.state)
end
