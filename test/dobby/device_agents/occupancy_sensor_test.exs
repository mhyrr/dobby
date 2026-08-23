defmodule Dobby.DeviceAgents.OccupancySensorTest do
  @moduledoc """
  The deterministic layer for motion, occupancy, and presence sensors.

  The discovery judgment matters more than the sync: a motion sensor on the
  same HA device as a camera or doorbell belongs to *that* device, and
  proposing it separately would put two names on one corner of the porch.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.OccupancySensor
  alias Dobby.HomeAssistant.Entity
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.OccupancySensor,
    bindings: %{occupancy: "binary_sensor.contract"},
    entity: [entity_id: "binary_sensor.contract", device_class: "motion"]
  )

  test "discovery takes the presence classes and leaves the rest of binary_sensor" do
    for presence <- ["motion", "occupancy", "presence"] do
      assert OccupancySensor.matches_entity?(entity(presence))
    end

    for other <- ["door", "smoke", "connectivity", nil] do
      refute OccupancySensor.matches_entity?(entity(other))
    end
  end

  test "a motion sensor beside a camera or doorbell yields to the compound device" do
    anchor = entity("motion")

    assert :ignore =
             OccupancySensor.discovery_bindings(anchor, [
               anchor,
               %Entity{entity_id: "camera.porch"}
             ])

    assert :ignore =
             OccupancySensor.discovery_bindings(anchor, [
               anchor,
               %Entity{entity_id: "event.porch", device_class: "doorbell"}
             ])

    assert {:ok, %{occupancy: "binary_sensor.test"}} =
             OccupancySensor.discovery_bindings(anchor, [anchor])
  end

  test "the first report is arrival; the hall actually clearing moves" do
    state = booted_state()

    {state, %Emit{signal: boot}} = sync(state, "on")
    assert :occupied in boot.data.changed
    assert boot.data.moved == []
    assert state.occupied

    {state, %Emit{signal: cleared}} = sync(state, "off")
    assert :occupied in cleared.data.moved
    refute state.occupied
  end

  test "occupancy reports; nobody commands it" do
    refute OccupancySensor.intervention?(:occupied)
    refute OccupancySensor.intervention?(:available)
    assert OccupancySensor.scheduled_actions() == %{}
    assert OccupancySensor.tools() == [Dobby.Tools.OccupancySensorGetStatus]
  end

  defp entity(device_class) do
    %Entity{entity_id: "binary_sensor.test", device_class: device_class}
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "occupancy:test",
      name: "test occupancy",
      agent_module: OccupancySensor,
      bindings: %{occupancy: "binary_sensor.test"},
      settings: %{}
    }

    OccupancySensor.new(id: device.id, state: OccupancySensor.initial_state(device)).state
  end

  defp sync(state, entity_state) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: %{}}

    case OccupancySensor.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
