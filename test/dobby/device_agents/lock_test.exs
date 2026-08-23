defmodule Dobby.DeviceAgents.LockTest do
  @moduledoc """
  The deterministic layer for the lock, whose write surface is one-way.

  The thread-level consequences — the record line, the one-shot echo swallow —
  are proven in `Dobby.InterventionsTest` against the rig. What lives here is
  the judgment underneath them: what the action emits, what the sync decides
  was commanded, and when the standing command is consumed.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Lock
  alias Dobby.Directive.HACall
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.Lock,
    bindings: %{lock: "lock.contract"},
    entity: [entity_id: "lock.contract"]
  )

  # `available` is nil between agent start and the first sync — a command in
  # that window deserves a refusal, not a crash.
  test "a secure command before the first sync is refused, not crashed" do
    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Lock.Secure.run(%{ref: "boot"}, %{state: booted_state()})

    assert reason =~ "unavailable"
  end

  test "an accepted secure emits exactly HA's lock call and nothing broader" do
    {state, _signal} = sync(booted_state(), "unlocked")

    assert {:ok, %{last_command: %{result: :accepted, action: :secure}},
            [%HACall{domain: "lock", service: "lock", entity_id: "lock.test", data: data}]} =
             Lock.Secure.run(%{ref: "cmd"}, %{state: state})

    assert data == %{}
  end

  test "the echo is one-shot: in flight through :locking, consumed at :locked" do
    {state, _signal} = sync(booted_state(), "unlocked")
    {:ok, command, _calls} = Lock.Secure.run(%{ref: "cmd"}, %{state: state})
    state = Map.merge(state, command)

    # Hardware that reports the transition: still Dobby's echo, still standing.
    {state, %Emit{signal: locking}} = sync(state, "locking")
    assert locking.data.commanded?
    assert state.last_command

    # The echo lands, and the command is spent with it.
    {state, %Emit{signal: locked}} = sync(state, "locked")
    assert locked.data.commanded?
    assert state.last_command == nil

    # So a later hand on the deadbolt is nobody's echo.
    {state, _signal} = sync(state, "unlocked")
    {_state, %Emit{signal: hand}} = sync(state, "locked")
    refute hand.data.commanded?
  end

  test "HA's lock vocabulary maps to Dobby's, and a stranger word maps to nothing" do
    assert {%{lock_state: :jammed}, _signal} = sync(booted_state(), "jammed")
    assert {%{lock_state: nil, available: true}, _signal} = sync(booted_state(), "surprise")
  end

  test "a moved deadbolt is somebody's doing; appearing and disappearing are not" do
    assert Lock.intervention?(:lock_state)
    refute Lock.intervention?(:available)
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "lock:test",
      name: "test lock",
      agent_module: Lock,
      bindings: %{lock: "lock.test"},
      settings: %{}
    }

    Lock.new(id: device.id, state: Lock.initial_state(device)).state
  end

  defp sync(state, entity_state) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: %{}}

    case Lock.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
