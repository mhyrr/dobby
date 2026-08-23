defmodule Dobby.DeviceAgents.LockTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Lock,
    bindings: %{lock: "lock.contract"},
    entity: [entity_id: "lock.contract"]
  )
end
