defmodule Dobby.DeviceAgents.RefrigeratorTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Refrigerator

  device_agent_contract(Dobby.DeviceAgents.Refrigerator,
    bindings: %{refrigerator_target_temperature: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "readings cannot become commands or automatic discovery guesses" do
    assert Refrigerator.scheduled_actions() == %{}
    assert Refrigerator.tools() == [Dobby.Tools.RefrigeratorGetStatus]

    for attribute <- [:readings, :units, :available],
        do: refute(Refrigerator.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "sensor.oven_temperature", "sensor.dishwasher_state"] do
      refute Refrigerator.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end

  test "bindings must name distinct scalar reading entities" do
    device = %Dobby.Home.Device{
      id: "refrigerator:test",
      name: "test refrigerator",
      agent_module: Refrigerator,
      bindings: %{},
      settings: %{}
    }

    assert {:error, _} = Refrigerator.validate_device(device)

    assert {:error, _} =
             Refrigerator.validate_device(%{
               device
               | bindings: %{refrigerator_target_temperature: "climate.oven"}
             })

    assert {:error, _} =
             Refrigerator.validate_device(%{
               device
               | bindings: %{refrigerator_target_temperature: "sensor."}
             })

    assert {:error, _} =
             Refrigerator.validate_device(%{device | bindings: %{invented: "sensor.fake"}})
  end
end
