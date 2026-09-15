defmodule Dobby.DeviceAgents.RangeHood.SyncState do
  @moduledoc "Keeps the range hood's fan and filter observations in one household snapshot."
  use Jido.Action,
    name: "range_hood_sync_state",
    description: "Applies HA observations to a range hood",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  @impl true
  def run(params, context),
    do:
      Dobby.DeviceAgents.Ventilation.sync(
        params,
        context.state,
        Dobby.DeviceAgents.RangeHood.reading_types(),
        :range_hood
      )
end
