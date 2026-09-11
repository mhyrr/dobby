defmodule Dobby.DeviceAgents.WasherTest do
  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Washer

  device_agent_contract(Dobby.DeviceAgents.Washer,
    bindings: %{operation_state: "sensor.contract"},
    entity: [entity_id: "sensor.contract"],
    discovery: :manual
  )

  test "readings cannot become commands or automatic discovery guesses" do
    assert Washer.scheduled_actions() == %{}
    assert Washer.tools() == [Dobby.Tools.WasherGetStatus]

    for attribute <- [:readings, :units, :available],
        do: refute(Washer.intervention?(attribute))

    for entity_id <- ["climate.kitchen", "sensor.oven_temperature", "sensor.washer_state"] do
      refute Washer.matches_entity?(%Dobby.HomeAssistant.Entity{entity_id: entity_id})
    end
  end

  test "bindings must name distinct scalar reading entities" do
    device = %Dobby.Home.Device{
      id: "washer:test",
      name: "test washer",
      agent_module: Washer,
      bindings: %{},
      settings: %{}
    }

    assert {:error, _} = Washer.validate_device(device)

    assert {:error, _} =
             Washer.validate_device(%{device | bindings: %{operation_state: "climate.oven"}})

    assert {:error, _} =
             Washer.validate_device(%{device | bindings: %{operation_state: "sensor."}})

    assert {:error, _} =
             Washer.validate_device(%{device | bindings: %{invented: "sensor.fake"}})
  end
end
