defmodule Dobby.DeviceAgents.ContactSensorTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.ContactSensor,
    bindings: %{contact: "binary_sensor.contract_door"},
    entity: [entity_id: "binary_sensor.contract_door", device_class: "door"]
  )
end
