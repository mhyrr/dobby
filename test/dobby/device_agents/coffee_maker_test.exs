defmodule Dobby.DeviceAgents.CoffeeMakerTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.CoffeeMaker

  device_agent_contract(Dobby.DeviceAgents.CoffeeMaker,
    bindings: %{operation_state: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "explicit observations do not become commands or discovery guesses" do
    assert CoffeeMaker.scheduled_actions() == %{}
    assert CoffeeMaker.tools() == [Dobby.Tools.CoffeeMakerGetStatus]
    assert [{"ha.state_changed", _action}] = CoffeeMaker.signal_routes()

    for attribute <- [:readings, :units, :available],
        do: refute(CoffeeMaker.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "switch.coffee_maker", "sensor.coffee_maker"] do
      refute CoffeeMaker.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end
end
