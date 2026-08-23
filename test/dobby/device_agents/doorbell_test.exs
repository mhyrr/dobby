defmodule Dobby.DeviceAgents.DoorbellTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Doorbell,
    bindings: %{event: "event.contract", camera: "camera.contract"},
    entity: [entity_id: "event.contract", device_class: "doorbell"],
    related: [
      [entity_id: "event.contract", device_class: "doorbell"],
      [entity_id: "camera.contract"]
    ]
  )
end
