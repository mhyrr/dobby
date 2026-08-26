defmodule Dobby.DeviceAgents.SafetySensorTest do
  @moduledoc """
  The deterministic layer for life-safety detectors.

  Read-only is the policy, not a gap: a detector observes a hazard, and
  nothing conversational should be able to quiet one. The hazard word is
  Dobby's, not HA's — "moisture" is a device class, "water" is what a
  household is actually worried about.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.SafetySensor
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.SafetySensor,
    bindings: %{alarm: "binary_sensor.contract"},
    entity: [entity_id: "binary_sensor.contract", device_class: "smoke"]
  )

  test "discovery takes the life-safety classes and leaves the rest of binary_sensor" do
    for hazard <- ["smoke", "carbon_monoxide", "gas", "moisture", "heat", "cold"] do
      assert SafetySensor.matches_entity?(entity(hazard))
    end

    for other <- ["door", "motion", "connectivity", nil] do
      refute SafetySensor.matches_entity?(entity(other))
    end
  end

  test "HA's device class becomes a household hazard word" do
    state = booted_state()

    {state, _emit} = sync(state, "off", "moisture")
    assert state.hazard == :water

    {state, _emit} = sync(state, "off", "carbon_monoxide")
    assert state.hazard == :carbon_monoxide
  end

  test "the first report is arrival; the alarm actually sounding moves" do
    state = booted_state()

    {state, %Emit{signal: boot}} = sync(state, "off", "smoke")
    assert :alarm in boot.data.changed
    assert boot.data.moved == []
    refute state.alarm

    {state, %Emit{signal: sounding}} = sync(state, "on", "smoke")
    assert :alarm in sounding.data.moved
    assert state.alarm
  end

  test "a detector reports; nothing may command one" do
    refute SafetySensor.intervention?(:alarm)
    refute SafetySensor.intervention?(:hazard)
    refute SafetySensor.intervention?(:available)
    assert SafetySensor.scheduled_actions() == %{}
    assert SafetySensor.tools() == [Dobby.Tools.SafetySensorGetStatus]
  end

  defp entity(device_class) do
    %Dobby.HomeAssistant.Entity{entity_id: "binary_sensor.test", device_class: device_class}
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "safety:test",
      name: "test detector",
      agent_module: SafetySensor,
      bindings: %{alarm: "binary_sensor.test"},
      settings: %{}
    }

    SafetySensor.new(id: device.id, state: SafetySensor.initial_state(device)).state
  end

  defp sync(state, entity_state, device_class) do
    params = %{
      entity_id: state.entity_id,
      state: entity_state,
      attributes: %{"device_class" => device_class}
    }

    case SafetySensor.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
