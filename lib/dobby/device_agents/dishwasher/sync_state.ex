defmodule Dobby.DeviceAgents.Dishwasher.SyncState do
  @moduledoc "Applies bound HA readings without implying an appliance command."

  use Jido.Action,
    name: "dishwasher_sync_state",
    description: "Applies a Home Assistant state change to a dishwasher",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.Dishwasher.sync(params, context.state)
end
