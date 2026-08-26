defmodule Dobby.DeviceAgents.DoorbellTest do
  @moduledoc """
  The deterministic layer for the doorbell.

  The ring's thread line is proven in `Dobby.InterventionsTest`; what is
  pinned here is the mechanism it rides on. `last_event` stays "ring" between
  two rings, so the *timestamp* is what moves per press — and it is the one
  attribute this type calls an intervention (Greg, 2026-08-23).
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Doorbell
  alias Dobby.HomeAssistant.Entity
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.Doorbell,
    bindings: %{event: "event.contract", camera: "camera.contract"},
    entity: [entity_id: "event.contract", device_class: "doorbell"],
    related: [
      [entity_id: "event.contract", device_class: "doorbell"],
      [entity_id: "camera.contract"]
    ]
  )

  test "discovery claims the whole HA device: event, camera, and motion" do
    anchor = %Entity{entity_id: "event.front", device_class: "doorbell"}

    related = [
      anchor,
      %Entity{entity_id: "camera.front"},
      %Entity{entity_id: "binary_sensor.front_motion", device_class: "motion"}
    ]

    assert {:ok,
            %{
              event: "event.front",
              camera: "camera.front",
              motion: "binary_sensor.front_motion"
            }} = Doorbell.discovery_bindings(anchor, related)
  end

  test "the first ring after boot is the house learning the bell; the second is a press" do
    state = booted_state()

    {state, %Emit{signal: boot}} = ring(state, "2026-08-23T12:00:00+00:00")
    assert :last_event_at in boot.data.changed
    assert boot.data.moved == []

    {_state, %Emit{signal: press}} = ring(state, "2026-08-23T18:30:00+00:00")
    assert press.data.moved == [:last_event_at]
    assert press.data.snapshot.last_event == "ring"
  end

  test "only the timestamp of a ring is somebody's doing" do
    assert Doorbell.intervention?(:last_event_at)

    # `last_event` stays "ring" between presses and would announce only the
    # first; camera and motion are observed, not done.
    for attribute <- [:last_event, :camera_available, :motion, :available] do
      refute Doorbell.intervention?(attribute)
    end
  end

  test "each bound entity updates its own slice, and a stranger updates nothing" do
    state = booted_state()

    assert {:ok, %{camera_available: true}, [_camera_emit]} =
             Doorbell.SyncState.run(
               %{entity_id: "camera.test", state: "idle", attributes: %{}},
               %{state: state}
             )

    assert {:ok, %{motion: true}, [_emit]} =
             Doorbell.SyncState.run(
               %{entity_id: "binary_sensor.test_motion", state: "on", attributes: %{}},
               %{state: state}
             )

    assert {:ok, %{}} =
             Doorbell.SyncState.run(
               %{entity_id: "light.unrelated", state: "on", attributes: %{}},
               %{state: state}
             )
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "doorbell:test",
      name: "test doorbell",
      agent_module: Doorbell,
      bindings: %{
        event: "event.test",
        camera: "camera.test",
        motion: "binary_sensor.test_motion"
      },
      settings: %{}
    }

    Doorbell.new(id: device.id, state: Doorbell.initial_state(device)).state
  end

  defp ring(state, timestamp) do
    params = %{
      entity_id: "event.test",
      state: timestamp,
      attributes: %{"event_type" => "ring", "device_class" => "doorbell"}
    }

    case Doorbell.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
