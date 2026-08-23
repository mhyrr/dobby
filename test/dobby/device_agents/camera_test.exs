defmodule Dobby.DeviceAgents.CameraTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Camera,
    bindings: %{camera: "camera.contract", motion: "binary_sensor.contract_motion"},
    entity: [entity_id: "camera.contract"],
    related: [
      [entity_id: "camera.contract"],
      [entity_id: "binary_sensor.contract_motion", device_class: "motion"]
    ]
  )
end
