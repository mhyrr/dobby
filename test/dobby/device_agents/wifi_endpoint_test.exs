defmodule Dobby.DeviceAgents.WifiEndpointTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.WifiEndpoint,
    bindings: %{connectivity: "binary_sensor.contract_connectivity"},
    entity: [
      entity_id: "binary_sensor.contract_connectivity",
      device_class: "connectivity"
    ]
  )
end
