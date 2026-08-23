defmodule Dobby.DeviceAgents.OccupancySensorTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.OccupancySensor,
    bindings: %{occupancy: "binary_sensor.contract_occupancy"},
    entity: [entity_id: "binary_sensor.contract_occupancy", device_class: "occupancy"]
  )
end
