defmodule Dobby.DeviceAgents.CameraTest do
  @moduledoc """
  The deterministic layer for the camera, which is read-only on purpose.

  The discovery judgment is the part worth pinning: a camera on the same HA
  device as a doorbell event is the *doorbell's* camera, and proposing it
  separately would give the household two names for one thing at the door.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Camera
  alias Dobby.HomeAssistant.Entity

  device_agent_contract(Dobby.DeviceAgents.Camera,
    bindings: %{camera: "camera.contract", motion: "binary_sensor.contract_motion"},
    entity: [entity_id: "camera.contract"],
    related: [
      [entity_id: "camera.contract"],
      [entity_id: "binary_sensor.contract_motion", device_class: "motion"]
    ]
  )

  test "a camera beside a doorbell event yields to the doorbell" do
    anchor = %Entity{entity_id: "camera.front"}
    doorbell = %Entity{entity_id: "event.front", device_class: "doorbell"}

    assert :ignore = Camera.discovery_bindings(anchor, [anchor, doorbell])
  end

  test "a lone camera binds itself, and claims a sibling motion sensor when it has one" do
    anchor = %Entity{entity_id: "camera.back_yard"}
    motion = %Entity{entity_id: "binary_sensor.back_motion", device_class: "motion"}

    assert {:ok, %{camera: "camera.back_yard"}} = Camera.discovery_bindings(anchor, [anchor])

    assert {:ok, %{camera: "camera.back_yard", motion: "binary_sensor.back_motion"}} =
             Camera.discovery_bindings(anchor, [anchor, motion])
  end

  test "each bound entity updates its own slice, and a stranger updates nothing" do
    state = booted_state()

    assert {:ok, %{available: true, activity: :recording}, [_emit]} =
             Camera.SyncState.run(
               %{entity_id: "camera.test", state: "recording", attributes: %{}},
               %{state: state}
             )

    assert {:ok, %{motion: true}, [_emit]} =
             Camera.SyncState.run(
               %{entity_id: "binary_sensor.test_motion", state: "on", attributes: %{}},
               %{state: state}
             )

    assert {:ok, %{}} =
             Camera.SyncState.run(
               %{entity_id: "light.unrelated", state: "on", attributes: %{}},
               %{state: state}
             )
  end

  test "nothing a camera observes is somebody's doing" do
    for attribute <- [:activity, :motion, :available] do
      refute Camera.intervention?(attribute)
    end

    assert Camera.scheduled_actions() == %{}
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "camera:test",
      name: "test camera",
      agent_module: Camera,
      bindings: %{camera: "camera.test", motion: "binary_sensor.test_motion"},
      settings: %{}
    }

    Camera.new(id: device.id, state: Camera.initial_state(device)).state
  end
end
