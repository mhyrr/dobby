defmodule Dobby.DeviceAgents.VacuumTest do
  @moduledoc """
  The deterministic layer for vacuums, with no model anywhere near it.

  Same architecture as the thermostat and light suites: commands go out as
  `HACall`s, FakeHA moves the world, and agent state changes only when the
  world comes back.
  """

  use Dobby.RigCase, async: false

  import Dobby.DeviceAgentContract

  device_agent_contract(Dobby.DeviceAgents.Vacuum,
    bindings: %{vacuum: "vacuum.contract"},
    entity: [entity_id: "vacuum.contract"],
    # :returning is the first honest answer to a dock command — the robot has
    # heard it and is on its way, which is not the same as being home.
    arrivals: [
      {%{result: :accepted, action: :start_cleaning}, %{activity: :cleaning},
       %{activity: :docked}},
      {%{result: :accepted, action: :dock}, %{activity: :returning}, %{activity: :cleaning}}
    ]
  )

  alias Dobby.Tools.{VacuumDock, VacuumGetStatus, VacuumStart}

  @vacuum "vacuum:robo"
  @entity "vacuum.robo"

  describe "state interpretation" do
    test "a docked robot reads as docked with its battery" do
      seed_house(%{@entity => vacuum_entity(activity: "docked", battery: 87)})

      state = agent_state(@vacuum)

      assert state.available
      assert state.activity == :docked
      assert state.battery_percent == 87
    end

    test "an activity outside the vocabulary reads as not known, not invented" do
      seed_house(%{@entity => vacuum_entity(activity: "polishing_the_silver")})

      state = agent_state(@vacuum)

      assert state.available
      assert state.activity == nil
    end
  end

  describe "start and dock" do
    setup do
      seed_house(%{@entity => vacuum_entity(activity: "docked")})
      :ok
    end

    test "starting reaches HA as vacuum.start, and state follows the confirm loop" do
      assert {:ok, result} = Jido.Exec.run(VacuumStart, %{device: @vacuum})
      assert result.accepted

      assert_receive {:ha_call, %HACall{domain: "vacuum", service: "start", entity_id: @entity}},
                     2_000

      assert_receive %Jido.Signal{
                       type: "dobby.device.state_changed",
                       data: %{snapshot: snapshot}
                     },
                     2_000

      assert snapshot.activity == :cleaning
      assert agent_state(@vacuum).activity == :cleaning
    end

    test "docking reaches HA as vacuum.return_to_base" do
      Fake.inject_state_changed(@entity, vacuum_entity(activity: "cleaning", battery: 70))
      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000

      assert {:ok, result} = Jido.Exec.run(VacuumDock, %{device: @vacuum})
      assert result.accepted

      assert_receive {:ha_call,
                      %HACall{domain: "vacuum", service: "return_to_base", entity_id: @entity}},
                     2_000

      assert_receive %Jido.Signal{
                       type: "dobby.device.state_changed",
                       data: %{snapshot: snapshot}
                     },
                     2_000

      assert snapshot.activity == :returning
    end

    test "an unavailable vacuum is refused rather than commanded blind" do
      Fake.inject_state_changed(@entity, %{state: "unavailable", attributes: %{}})
      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000

      assert {:ok, result} = Jido.Exec.run(VacuumStart, %{device: @vacuum})

      refute result.accepted
      assert result.reason =~ "unavailable"
      assert Fake.trace() == []
    end
  end

  # A robot docks itself, empties itself and gets stuck by itself. None of
  # that is somebody doing something, so none of it reaches the thread.
  test "nothing a vacuum does on its own is somebody's hand on it" do
    for attribute <- [:activity, :battery_percent, :available] do
      refute Dobby.DeviceAgents.Vacuum.intervention?(attribute)
    end
  end

  describe "get_status" do
    test "answers from agent state with no HA round trip" do
      seed_house(%{@entity => vacuum_entity(activity: "cleaning", battery: 42)})

      assert {:ok, status} = Jido.Exec.run(VacuumGetStatus, %{device: @vacuum})

      assert status.device == @vacuum
      assert status.name == "robot vacuum"
      assert status.activity == :cleaning
      assert status.battery_percent == 42
      assert status.available

      assert Fake.trace() == []
    end
  end
end
