defmodule Dobby.DeviceAgents.OvenTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Oven

  device_agent_contract(Dobby.DeviceAgents.Oven,
    bindings: %{temperature: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "readings cannot become commands or automatic discovery guesses" do
    assert Oven.scheduled_actions() == %{}
    assert Oven.tools() == [Dobby.Tools.OvenGetStatus]
    for attribute <- [:readings, :units, :available], do: refute(Oven.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "sensor.oven_temperature", "sensor.dishwasher_state"] do
      refute Oven.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end

  test "bindings must name distinct scalar reading entities" do
    device = %Dobby.Home.Device{
      id: "oven:test",
      name: "test oven",
      agent_module: Oven,
      bindings: %{},
      settings: %{}
    }

    assert {:error, _} = Oven.validate_device(device)

    assert {:error, _} =
             Oven.validate_device(%{device | bindings: %{temperature: "climate.oven"}})

    assert {:error, _} = Oven.validate_device(%{device | bindings: %{temperature: "sensor."}})
    assert {:error, _} = Oven.validate_device(%{device | bindings: %{invented: "sensor.fake"}})
  end
end
