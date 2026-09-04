defmodule Dobby.DeviceAgents.ShadeTest do
  @moduledoc """
  The deterministic layer for blinds, shades, curtains, shutters, and awnings.

  Open and close are portable across every cover; a stated position is not,
  and rides HA's `SET_POSITION` feature bit. The boundary with AccessCover is
  tested from the access side (`access_cover_test.exs`), in both directions.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Shade
  alias Dobby.Directive.HACall
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.Shade,
    bindings: %{cover: "cover.contract"},
    entity: [entity_id: "cover.contract", device_class: "shade"],
    arrivals: [
      {%{result: :accepted, action: :open}, %{shade_state: :opening}, %{shade_state: :closed}},
      {%{result: :accepted, action: :close}, %{shade_state: :closing}, %{shade_state: :open}},
      {%{result: :accepted, action: :set_position, position: 40}, %{position: 40},
       %{position: 60}}
    ]
  )

  # `available` is nil between agent start and the first sync — a command in
  # that window deserves a refusal, not an `ArgumentError` from `not nil`.
  test "a command before the first sync is refused, not crashed" do
    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Shade.SetPosition.run(%{position: 40, ref: "boot"}, %{state: booted_state()})

    assert reason =~ "unavailable"
  end

  test "a shade without the position feature refuses a percentage, and no call leaves" do
    {state, _emit} = sync(booted_state(), "open", %{"supported_features" => 0})
    refute state.supports_position

    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Shade.SetPosition.run(%{position: 40, ref: "cmd"}, %{state: state})

    assert reason =~ "does not support position"
  end

  test "an allowed position emits exactly HA's set_cover_position call" do
    {state, _emit} = sync(booted_state(), "open", %{"supported_features" => 4})

    assert {:ok, %{last_command: %{result: :accepted, position: 20}},
            [
              %HACall{
                domain: "cover",
                service: "set_cover_position",
                entity_id: "cover.test",
                data: %{position: 20}
              }
            ]} = Shade.SetPosition.run(%{position: 20, ref: "cmd"}, %{state: state})
  end

  test "each movement emits exactly HA's cover call, with no position feature needed" do
    {state, _emit} = sync(booted_state(), "closed", %{"supported_features" => 0})

    assert {:ok, %{last_command: %{result: :accepted, action: :open}},
            [%HACall{domain: "cover", service: "open_cover", data: %{}}]} =
             Shade.Move.run(%{movement: :open, ref: "cmd"}, %{state: state})

    assert {:ok, _accepted, [%HACall{domain: "cover", service: "close_cover"}]} =
             Shade.Move.run(%{movement: :close, ref: "cmd"}, %{state: state})
  end

  test "the echo of a commanded position is commanded; a hand on the wand is not" do
    {state, _emit} =
      sync(booted_state(), "open", %{"current_position" => 80, "supported_features" => 4})

    {:ok, command, _calls} = Shade.SetPosition.run(%{position: 20, ref: "cmd"}, %{state: state})
    state = Map.merge(state, command)

    {state, %Emit{signal: echo}} =
      sync(state, "open", %{"current_position" => 20, "supported_features" => 4})

    assert echo.data.commanded?

    {_state, %Emit{signal: hand}} =
      sync(state, "open", %{"current_position" => 55, "supported_features" => 4})

    refute hand.data.commanded?
  end

  test "movement and position are somebody's doing; discovery and availability are not" do
    assert Shade.intervention?(:shade_state)
    assert Shade.intervention?(:position)
    refute Shade.intervention?(:supports_position)
    refute Shade.intervention?(:available)
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "shade:test",
      name: "test shade",
      agent_module: Shade,
      bindings: %{cover: "cover.test"},
      settings: %{}
    }

    Shade.new(id: device.id, state: Shade.initial_state(device)).state
  end

  defp sync(state, entity_state, attributes) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: attributes}

    case Shade.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
