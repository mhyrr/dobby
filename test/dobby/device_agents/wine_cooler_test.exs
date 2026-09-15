defmodule Dobby.DeviceAgents.WineCoolerTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.WineCooler

  device_agent_contract(Dobby.DeviceAgents.WineCooler,
    bindings: %{temperature: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "explicit observations do not become commands or discovery guesses" do
    assert WineCooler.scheduled_actions() == %{}
    assert WineCooler.tools() == [Dobby.Tools.WineCoolerGetStatus]
    assert [{"ha.state_changed", _action}] = WineCooler.signal_routes()

    for attribute <- [:readings, :units, :available],
        do: refute(WineCooler.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "switch.wine_cooler", "sensor.wine_cooler"] do
      refute WineCooler.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end
end
