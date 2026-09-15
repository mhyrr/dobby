defmodule Dobby.DeviceAgents.IceMaker.SyncState do
  @moduledoc "Applies bound HA readings without implying an appliance command."

  use Jido.Action,
    name: "ice_maker_sync_state",
    description: "Applies a Home Assistant state change to an ice maker",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.IceMaker.sync(params, context.state)
end
