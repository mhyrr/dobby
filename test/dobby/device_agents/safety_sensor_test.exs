defmodule Dobby.DeviceAgents.SafetySensorTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.SafetySensor,
    bindings: %{alarm: "binary_sensor.contract_smoke"},
    entity: [entity_id: "binary_sensor.contract_smoke", device_class: "smoke"]
  )
end
