defmodule Dobby.DeviceAgents.ContactSensorTest do
  @moduledoc """
  The deterministic layer for door, window, and garage contacts.

  A contact is read-only and its discovery is a matter of device class: HA's
  `binary_sensor` domain also holds motion, smoke, and connectivity, and each
  of those is a different Dobby type with different consequences.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.ContactSensor
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.ContactSensor,
    bindings: %{contact: "binary_sensor.contract"},
    entity: [entity_id: "binary_sensor.contract", device_class: "door"]
  )

  test "discovery takes the opening classes and leaves the rest of binary_sensor" do
    for opening <- ["door", "window", "garage_door", "opening"] do
      assert ContactSensor.matches_entity?(entity(opening))
    end

    for other <- ["motion", "smoke", "connectivity", nil] do
      refute ContactSensor.matches_entity?(entity(other))
    end
  end

  test "the first report is arrival; the door actually opening moves" do
    state = booted_state()

    {state, %Emit{signal: boot}} = sync(state, "off")
    assert :open in boot.data.changed
    assert boot.data.moved == []
    refute state.open

    {state, %Emit{signal: opened}} = sync(state, "on")
    assert :open in opened.data.moved
    assert state.open
  end

  test "a contact reports; nobody commands one" do
    refute ContactSensor.intervention?(:open)
    refute ContactSensor.intervention?(:available)
    assert ContactSensor.scheduled_actions() == %{}
    assert ContactSensor.tools() == [Dobby.Tools.ContactSensorGetStatus]
  end

  defp entity(device_class) do
    %Dobby.HomeAssistant.Entity{entity_id: "binary_sensor.test", device_class: device_class}
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "contact:test",
      name: "test contact",
      agent_module: ContactSensor,
      bindings: %{contact: "binary_sensor.test"},
      settings: %{}
    }

    ContactSensor.new(id: device.id, state: ContactSensor.initial_state(device)).state
  end

  defp sync(state, entity_state) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: %{}}

    case ContactSensor.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
