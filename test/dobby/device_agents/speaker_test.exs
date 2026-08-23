defmodule Dobby.DeviceAgents.SpeakerTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Speaker,
    bindings: %{media_player: "media_player.contract"},
    entity: [entity_id: "media_player.contract", device_class: "speaker"]
  )
end
