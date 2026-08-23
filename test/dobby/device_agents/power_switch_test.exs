defmodule Dobby.DeviceAgents.PowerSwitchTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.PowerSwitch,
    bindings: %{switch: "switch.contract"},
    entity: [entity_id: "switch.contract"]
  )
end
