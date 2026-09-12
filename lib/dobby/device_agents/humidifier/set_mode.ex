defmodule Dobby.DeviceAgents.Humidifier.SetMode do
  @moduledoc "Keeps the humidifier signal route on the shared HA humidity contract."
  use Jido.Action,
    name: "humidifier_set_mode",
    description: "SetMode for a household humidifier",
    schema: [mode: [type: :string, required: true], ref: [type: :string, required: true]]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Humidity.set_mode(params, context.state)
end
