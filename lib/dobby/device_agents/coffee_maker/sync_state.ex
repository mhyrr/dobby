defmodule Dobby.DeviceAgents.CoffeeMaker.SyncState do
  @moduledoc "Applies bound HA readings without implying an appliance command."

  use Jido.Action,
    name: "coffee_maker_sync_state",
    description: "Applies a Home Assistant state change to a coffee_maker",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  @impl true
  def run(params, context), do: Dobby.DeviceAgents.CoffeeMaker.sync(params, context.state)
end
