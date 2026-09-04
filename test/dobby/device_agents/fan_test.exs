defmodule Dobby.DeviceAgents.FanTest do
  @moduledoc """
  The deterministic layer for the fan.

  Speed control is discovered, not assumed: HA's `SET_SPEED` feature bit is
  the hardware's word on whether a percentage means anything, and the tests
  that matter here are the ones where that word was no.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Fan
  alias Dobby.Directive.HACall
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.Fan,
    bindings: %{fan: "fan.contract"},
    entity: [entity_id: "fan.contract"],
    arrivals: [
      {%{result: :accepted, action: :set_power, power: :on}, %{power: :on}, %{power: :off}},
      {%{result: :accepted, action: :set_speed, speed_percent: 35}, %{speed_percent: 35},
       %{speed_percent: 60}}
    ]
  )

  # `available` is nil between agent start and the first sync — a schedule
  # firing in that window deserves a refusal, not an `ArgumentError` from
  # `not nil`.
  test "a command before the first sync is refused, not crashed" do
    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Fan.SetSpeed.run(%{speed_percent: 50, ref: "boot"}, %{state: booted_state()})

    assert reason =~ "unavailable"
  end

  test "a fan without the speed feature refuses a percentage, and no call leaves" do
    {state, _emit} = sync(booted_state(), "on", %{"supported_features" => 0})
    refute state.supports_speed

    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Fan.SetSpeed.run(%{speed_percent: 50, ref: "cmd"}, %{state: state})

    assert reason =~ "does not support speed"
  end

  test "an allowed speed emits exactly HA's set_percentage call" do
    {state, _emit} = sync(booted_state(), "on", %{"supported_features" => 1})

    assert {:ok, %{last_command: %{result: :accepted, speed_percent: 65}},
            [
              %HACall{
                domain: "fan",
                service: "set_percentage",
                entity_id: "fan.test",
                data: %{percentage: 65}
              }
            ]} = Fan.SetSpeed.run(%{speed_percent: 65, ref: "cmd"}, %{state: state})
  end

  test "zero percent is refused toward turn_off rather than guessed at" do
    {state, _emit} = sync(booted_state(), "on", %{"supported_features" => 1})

    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Fan.SetSpeed.run(%{speed_percent: 0, ref: "cmd"}, %{state: state})

    assert reason =~ "between 1 and 100"
  end

  test "each power direction emits exactly HA's fan call" do
    {state, _emit} = sync(booted_state(), "off", %{})

    assert {:ok, _accepted, [%HACall{domain: "fan", service: "turn_on", data: %{}}]} =
             Fan.SetPower.run(%{power: :on, ref: "cmd"}, %{state: state})

    assert {:ok, _accepted, [%HACall{domain: "fan", service: "turn_off"}]} =
             Fan.SetPower.run(%{power: :off, ref: "cmd"}, %{state: state})
  end

  test "the first report is the house learning the fan, not an event" do
    {_state, %Emit{signal: signal}} =
      sync(booted_state(), "on", %{"percentage" => 35, "supported_features" => 1})

    assert :speed_percent in signal.data.changed
    assert signal.data.moved == []
  end

  test "the echo of a commanded speed is commanded; a hand on the pull chain is not" do
    {state, _emit} = sync(booted_state(), "on", %{"percentage" => 20, "supported_features" => 1})
    {:ok, command, _calls} = Fan.SetSpeed.run(%{speed_percent: 65, ref: "cmd"}, %{state: state})
    state = Map.merge(state, command)

    {state, %Emit{signal: echo}} =
      sync(state, "on", %{"percentage" => 65, "supported_features" => 1})

    assert echo.data.commanded?

    {_state, %Emit{signal: hand}} =
      sync(state, "on", %{"percentage" => 40, "supported_features" => 1})

    refute hand.data.commanded?
  end

  test "power and speed are somebody's doing; discovery and availability are not" do
    assert Fan.intervention?(:power)
    assert Fan.intervention?(:speed_percent)
    refute Fan.intervention?(:supports_speed)
    refute Fan.intervention?(:available)
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "fan:test",
      name: "test fan",
      agent_module: Fan,
      bindings: %{fan: "fan.test"},
      settings: %{}
    }

    Fan.new(id: device.id, state: Fan.initial_state(device)).state
  end

  defp sync(state, entity_state, attributes) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: attributes}

    case Fan.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
