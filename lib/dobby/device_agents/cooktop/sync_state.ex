defmodule Dobby.DeviceAgents.Cooktop.SyncState do
  @moduledoc "Applies bound HA readings without implying an appliance command."

  use Jido.Action,
    name: "cooktop_sync_state",
    description: "Applies a Home Assistant state change to a cooktop",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Cooktop.sync(params, context.state)
end
