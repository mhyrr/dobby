defmodule Dobby.DeviceAgents.IceMakerTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.IceMaker

  device_agent_contract(Dobby.DeviceAgents.IceMaker,
    bindings: %{operation_state: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "explicit observations do not become commands or discovery guesses" do
    assert IceMaker.scheduled_actions() == %{}
    assert IceMaker.tools() == [Dobby.Tools.IceMakerGetStatus]
    assert [{"ha.state_changed", _action}] = IceMaker.signal_routes()

    for attribute <- [:readings, :units, :available],
        do: refute(IceMaker.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "switch.ice_maker", "sensor.ice_maker"] do
      refute IceMaker.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end
end
