defmodule Dobby.DeviceAgents.Oven.SyncState do
  @moduledoc "Applies bound HA readings without implying an appliance command."

  use Jido.Action,
    name: "oven_sync_state",
    description: "Applies a Home Assistant state change to an oven",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Oven.sync(params, context.state)
end
