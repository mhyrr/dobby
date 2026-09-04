defmodule Dobby.DeviceAgents.AccessCoverTest do
  @moduledoc """
  The deterministic layer for the garage door, gate, door, and window.

  Same one-way write surface as the lock, and the same split of proof: the
  thread's echo swallow is shown in `Dobby.InterventionsTest` against the rig,
  and this file pins the judgment underneath — the emitted call, the commanded
  echo, and the line between this type and an ordinary shade.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.AccessCover
  alias Dobby.Directive.HACall
  alias Dobby.HomeAssistant.Entity
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.AccessCover,
    bindings: %{cover: "cover.contract"},
    entity: [entity_id: "cover.contract", device_class: "garage"],
    arrivals: [
      {%{result: :accepted, action: :close}, %{cover_state: :closing}, %{cover_state: :open}}
    ]
  )

  # `available` is nil between agent start and the first sync — a command in
  # that window deserves a refusal, not a crash.
  test "a close command before the first sync is refused, not crashed" do
    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             AccessCover.Close.run(%{ref: "boot"}, %{state: booted_state()})

    assert reason =~ "unavailable"
  end

  test "an accepted close emits exactly HA's close_cover call" do
    {state, _emit} = sync(booted_state(), "open", %{"current_position" => 100})

    assert {:ok, %{last_command: %{result: :accepted, action: :close}},
            [
              %HACall{
                domain: "cover",
                service: "close_cover",
                entity_id: "cover.test",
                data: data
              }
            ]} =
             AccessCover.Close.run(%{ref: "cmd"}, %{state: state})

    assert data == %{}
  end

  test "the echo is one-shot: in flight through :closing, consumed at :closed" do
    {state, _emit} = sync(booted_state(), "open", %{"current_position" => 100})
    {:ok, command, _calls} = AccessCover.Close.run(%{ref: "cmd"}, %{state: state})
    state = Map.merge(state, command)

    {state, %Emit{signal: closing}} = sync(state, "closing", %{"current_position" => 50})
    assert closing.data.commanded?
    assert state.last_command

    {state, %Emit{signal: closed}} = sync(state, "closed", %{"current_position" => 0})
    assert closed.data.commanded?
    assert state.last_command == nil

    # A later hand on the garage door is nobody's echo.
    {state, _emit} = sync(state, "open", %{"current_position" => 100})
    {_state, %Emit{signal: hand}} = sync(state, "closed", %{"current_position" => 0})
    refute hand.data.commanded?
  end

  test "access covers and shades divide HA's cover domain by consequence, not by domain" do
    for access <- ["door", "garage", "gate", "window"] do
      entity = %Entity{entity_id: "cover.access", device_class: access}
      assert AccessCover.matches_entity?(entity)
      refute Dobby.DeviceAgents.Shade.matches_entity?(entity)
    end

    for light_control <- ["awning", "blind", "curtain", "shade", "shutter"] do
      entity = %Entity{entity_id: "cover.shade", device_class: light_control}
      refute AccessCover.matches_entity?(entity)
      assert Dobby.DeviceAgents.Shade.matches_entity?(entity)
    end
  end

  test "movement and position are somebody's doing; availability is weather" do
    assert AccessCover.intervention?(:cover_state)
    assert AccessCover.intervention?(:position)
    refute AccessCover.intervention?(:available)
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "cover:test",
      name: "test garage door",
      agent_module: AccessCover,
      bindings: %{cover: "cover.test"},
      settings: %{}
    }

    AccessCover.new(id: device.id, state: AccessCover.initial_state(device)).state
  end

  defp sync(state, entity_state, attributes) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: attributes}

    case AccessCover.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
