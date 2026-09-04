defmodule Dobby.DeviceAgents.PowerSwitchTest do
  @moduledoc """
  The deterministic layer for plugs, outlets, and relays.

  The type's whole judgment is small — on, off, and whose doing a flip was —
  which is exactly why it gets pinned: a switch can power a heater, and the
  thread's answer to "who turned that on" rides on `commanded?/2`.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.PowerSwitch
  alias Dobby.Directive.HACall
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.PowerSwitch,
    bindings: %{switch: "switch.contract"},
    entity: [entity_id: "switch.contract"],
    arrivals: [
      {%{result: :accepted, action: :set_power, power: :on}, %{power: :on}, %{power: :off}}
    ]
  )

  # `available` is nil between agent start and the first sync — a command in
  # that window deserves a refusal, not a command sent blind.
  test "a command before the first sync is refused" do
    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             PowerSwitch.SetPower.run(%{power: :on, ref: "boot"}, %{state: booted_state()})

    assert reason =~ "unavailable"
  end

  test "each direction emits exactly HA's switch call" do
    {state, _emit} = sync(booted_state(), "off")

    assert {:ok, %{last_command: %{result: :accepted, power: :on}},
            [%HACall{domain: "switch", service: "turn_on", entity_id: "switch.test", data: %{}}]} =
             PowerSwitch.SetPower.run(%{power: :on, ref: "cmd"}, %{state: state})

    assert {:ok, _accepted, [%HACall{domain: "switch", service: "turn_off"}]} =
             PowerSwitch.SetPower.run(%{power: :off, ref: "cmd"}, %{state: state})
  end

  test "the echo of Dobby's command is commanded; a hand on the switch is not" do
    {state, _emit} = sync(booted_state(), "off")
    {:ok, command, _calls} = PowerSwitch.SetPower.run(%{power: :on, ref: "cmd"}, %{state: state})
    state = Map.merge(state, command)

    {state, %Emit{signal: echo}} = sync(state, "on")
    assert echo.data.commanded?

    # The switch's echo stands the way the thermostat's does: it misses only a
    # hand returning it to the exact commanded value, which for on/off means
    # `moved` back and forth. The flip *away* from the command is always a hand.
    {_state, %Emit{signal: hand}} = sync(state, "off")
    refute hand.data.commanded?
  end

  test "a flipped switch is somebody's doing; availability is not" do
    assert PowerSwitch.intervention?(:power)
    refute PowerSwitch.intervention?(:available)
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "switch:test",
      name: "test outlet",
      agent_module: PowerSwitch,
      bindings: %{switch: "switch.test"},
      settings: %{}
    }

    PowerSwitch.new(id: device.id, state: PowerSwitch.initial_state(device)).state
  end

  defp sync(state, entity_state) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: %{}}

    case PowerSwitch.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
