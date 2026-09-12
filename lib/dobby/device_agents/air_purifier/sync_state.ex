defmodule Dobby.DeviceAgents.AirPurifier.SyncState do
  @moduledoc "Keeps the air purifier's fan and filter observations in one household snapshot."
  use Jido.Action,
    name: "air_purifier_sync_state",
    description: "Applies HA observations to a air purifier",
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
        Dobby.DeviceAgents.AirPurifier.reading_types(),
        :air_purifier
      )
end
