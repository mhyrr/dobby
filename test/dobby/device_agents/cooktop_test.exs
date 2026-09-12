defmodule Dobby.DeviceAgents.CooktopTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Cooktop

  device_agent_contract(Dobby.DeviceAgents.Cooktop,
    bindings: %{operation_state: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "explicit observations do not become commands or discovery guesses" do
    assert Cooktop.scheduled_actions() == %{}
    assert Cooktop.tools() == [Dobby.Tools.CooktopGetStatus]
    assert [{"ha.state_changed", _action}] = Cooktop.signal_routes()

    for attribute <- [:readings, :units, :available],
        do: refute(Cooktop.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "switch.cooktop", "sensor.cooktop"] do
      refute Cooktop.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end
end
