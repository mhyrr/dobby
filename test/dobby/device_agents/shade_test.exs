defmodule Dobby.DeviceAgents.ShadeTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Shade,
    bindings: %{cover: "cover.contract"},
    entity: [entity_id: "cover.contract", device_class: "shade"]
  )
end
