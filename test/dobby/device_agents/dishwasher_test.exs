defmodule Dobby.DeviceAgents.DishwasherTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Dishwasher

  device_agent_contract(Dobby.DeviceAgents.Dishwasher,
    bindings: %{operation_state: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "readings cannot become commands or automatic discovery guesses" do
    assert Dishwasher.scheduled_actions() == %{}
    assert Dishwasher.tools() == [Dobby.Tools.DishwasherGetStatus]

    for attribute <- [:readings, :units, :available],
        do: refute(Dishwasher.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "sensor.oven_temperature", "sensor.dishwasher_state"] do
      refute Dishwasher.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end

  test "bindings must name distinct scalar reading entities" do
    device = %Dobby.Home.Device{
      id: "dishwasher:test",
      name: "test dishwasher",
      agent_module: Dishwasher,
      bindings: %{},
      settings: %{}
    }

    assert {:error, _} = Dishwasher.validate_device(device)

    assert {:error, _} =
             Dishwasher.validate_device(%{device | bindings: %{operation_state: "climate.oven"}})

    assert {:error, _} =
             Dishwasher.validate_device(%{device | bindings: %{operation_state: "sensor."}})

    assert {:error, _} =
             Dishwasher.validate_device(%{device | bindings: %{invented: "sensor.fake"}})
  end
end
