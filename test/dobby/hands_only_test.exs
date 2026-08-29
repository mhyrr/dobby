defmodule Dobby.HandsOnlyTest do
  @moduledoc """
  The language lock as one caller-aware protocol (TK-036).

  These scenarios use the rig's two locks: the side door is `hands_only`, and
  the front door is ordinary. The device type and tool are otherwise
  identical, so the only thing deciding the result is the trusted caller that
  crossed `Dobby.DeviceAgent.command/4`.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Controls
  alias Dobby.Schedules

  @front "lock:front"
  @side "lock:side"
  @front_entity "lock.front_door"
  @side_entity "lock.side_door"

  setup do
    seed_house(%{
      @front_entity => %{state: "unlocked", attributes: %{}},
      @side_entity => %{state: "unlocked", attributes: %{}}
    })

    :ok
  end

  test "the language tool is held on one lock and accepted on the other" do
    assert {:ok, %{accepted: false, reason: reason}} =
             Jido.Exec.run(Dobby.Tools.LockSecure, %{device: @side})

    assert reason =~ "hands only"
    assert reason =~ "language layer"
    assert Fake.trace() == []

    assert {:ok, %{accepted: true}} =
             Jido.Exec.run(Dobby.Tools.LockSecure, %{device: @front})

    assert_receive {:ha_call, %HACall{entity_id: @front_entity}}, 2_000
  end

  test "the direct card path still secures the hands-only lock" do
    assert {:ok, %{lock_state: :locked}} =
             Controls.secure_lock(@side, via: "greg, card")

    assert_receive {:ha_call, %HACall{entity_id: @side_entity}}, 2_000
    assert eventually(fn -> agent_state(@side).lock_state == :locked end)
  end

  test "language schedules are refused at authoring and an admin schedule fires" do
    assert {:error, conversation} =
             create_language_schedule(:conversation, "language lock")

    assert conversation =~ "hands only"

    assert {:error, mcp} = create_language_schedule(:mcp, "MCP lock")
    assert mcp =~ "hands only"

    assert {:ok, schedule} = create_admin_schedule("night lock")

    Dobby.SchedulerAgent.id()
    |> Dobby.Jido.whereis()
    |> Jido.AgentServer.cast(Schedules.fire_signal(schedule))

    assert_receive {:ha_call, %HACall{entity_id: @side_entity}}, 2_000
    assert eventually(fn -> agent_state(@side).lock_state == :locked end)
  end

  test "the roster says hands only without changing the board snapshot" do
    side = Enum.find(Dobby.Home.roster(), &(&1.id == @side))
    assert side.hands_only

    rendered = Dobby.DobbyAgent.RequestTransformer.render(%{})
    assert rendered =~ "lock:side"
    assert rendered =~ "hands only"

    snapshot = Dobby.Home.snapshots()[@side]
    refute Map.has_key?(snapshot, :hands_only)
  end

  defp create_language_schedule(via, label) do
    Dobby.Tools.CreateSchedule.run(
      %{
        label: label,
        cron: "0 23 * * *",
        device: @side,
        action: "secure",
        args: %{}
      },
      %{speaker: "greg", via: via}
    )
  end

  defp create_admin_schedule(label) do
    Schedules.create_schedule(%{
      label: label,
      cron: "0 23 * * *",
      timezone: Dobby.Home.manifest().timezone,
      target: @side,
      action: "secure",
      args: %{},
      created_by: "greg",
      created_via: :admin
    })
  end
end
