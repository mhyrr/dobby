defmodule Dobby.DeviceAgents.Humidifier.SyncState do
  @moduledoc "Keeps the humidifier signal route on the shared HA humidity contract."
  use Jido.Action,
    name: "humidifier_sync_state",
    description: "SyncState for a household humidifier",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Humidity.sync(params, context.state)
end
