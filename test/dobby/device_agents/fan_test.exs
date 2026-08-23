defmodule Dobby.DeviceAgents.FanTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Fan,
    bindings: %{fan: "fan.contract"},
    entity: [entity_id: "fan.contract"]
  )
end
