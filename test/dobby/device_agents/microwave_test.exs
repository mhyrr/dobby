defmodule Dobby.DeviceAgents.MicrowaveTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Microwave

  device_agent_contract(Dobby.DeviceAgents.Microwave,
    bindings: %{operation_state: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "explicit observations do not become commands or discovery guesses" do
    assert Microwave.scheduled_actions() == %{}
    assert Microwave.tools() == [Dobby.Tools.MicrowaveGetStatus]
    assert [{"ha.state_changed", _action}] = Microwave.signal_routes()

    for attribute <- [:readings, :units, :available],
        do: refute(Microwave.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "switch.microwave", "sensor.microwave"] do
      refute Microwave.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end
end
