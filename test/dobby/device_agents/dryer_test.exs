defmodule Dobby.DeviceAgents.DryerTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Dryer

  device_agent_contract(Dobby.DeviceAgents.Dryer,
    bindings: %{operation_state: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "readings cannot become commands or automatic discovery guesses" do
    assert Dryer.scheduled_actions() == %{}
    assert Dryer.tools() == [Dobby.Tools.DryerGetStatus]

    for attribute <- [:readings, :units, :available],
        do: refute(Dryer.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "sensor.oven_temperature", "sensor.dryer_state"] do
      refute Dryer.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end

  test "bindings must name distinct scalar reading entities" do
    device = %Dobby.Home.Device{
      id: "dryer:test",
      name: "test dryer",
      agent_module: Dryer,
      bindings: %{},
      settings: %{}
    }

    assert {:error, _} = Dryer.validate_device(device)

    assert {:error, _} =
             Dryer.validate_device(%{device | bindings: %{operation_state: "climate.oven"}})

    assert {:error, _} =
             Dryer.validate_device(%{device | bindings: %{operation_state: "sensor."}})

    assert {:error, _} =
             Dryer.validate_device(%{device | bindings: %{invented: "sensor.fake"}})
  end
end
