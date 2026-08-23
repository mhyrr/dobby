defmodule Dobby.DeviceAgents.AccessCoverTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.AccessCover,
    bindings: %{cover: "cover.contract"},
    entity: [entity_id: "cover.contract", device_class: "garage"]
  )
end
