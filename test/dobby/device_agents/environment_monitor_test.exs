defmodule Dobby.DeviceAgents.EnvironmentMonitorTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.EnvironmentMonitor,
    bindings: %{temperature: "sensor.contract_temperature"},
    entity: [entity_id: "sensor.contract_temperature", device_class: "temperature"]
  )
end
