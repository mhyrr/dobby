defmodule Dobby.RulesRuntimeTest do
  @moduledoc """
  Standing intentions through the real writer, database, and Fake HA boundary.
  Only elapsed time is supplied by the test; observations still travel through
  device agents and the production activity writer.
  """
  use Dobby.RigCase, async: false
  import Ecto.Query
  alias Dobby.{Conversation, Home, HomeConfig, Repo, Rules}
  alias Dobby.Rules.{Occurrence, Proposal, Rule, Watcher}
  @entity "climate.main_floor"
  @device "thermostat:main"
  @now ~U[2026-09-05 16:00:00.000000Z]

  setup do
    seed_house(%{@entity => thermostat_entity(current: 66, target: 68)})
    _ = :sys.get_state(Dobby.Jido.whereis(@device))
    settle_watcher!()
    Trace.reset()
    :ok
  end

  describe "authoring" do
    setup do
      %{config: writable_house!()}
    end

    test "proposal does not watch until a later household request confirms it", %{config: config} do
      assert {:ok, proposal} =
               Rules.propose(definition(),
                 actor: "greg",
                 via: :conversation,
                 request_id: "turn-1"
               )

      assert Rules.list() == []

      assert {:error, message} =
               Rules.confirm(proposal.id, actor: "greg", via: :conversation, request_id: "turn-1")

      assert message =~ "later message"
      assert Rules.list() == []

      assert {:ok, _} =
               Rules.confirm(proposal.id, actor: "maya", via: :conversation, request_id: "turn-2")

      assert [%{id: "cold-room", enabled: true}] = Rules.list()
      assert File.read!(config.path) =~ "cold-room"
      assert Repo.get!(Proposal, proposal.id).confirmed_by == "maya"
      assert Trace.ha_calls() == []
      assert Trace.llm_calls() == []
    end

    test "expired and superseded proposals cannot change the house" do
      assert {:ok, old} = Rules.propose(definition(), request_id: "old")
      assert {:error, expired} = Rules.confirm(old.id, now: DateTime.add(old.inserted_at, 86_400))
      assert expired =~ "over a day"

      assert {:ok, fresh} =
               Rules.propose(definition(%{"duration_seconds" => 120}), request_id: "fresh")

      assert {:error, superseded} = Rules.confirm(old.id)
      assert superseded =~ "superseded"
      assert Rules.list() == []
      assert {:ok, _} = Rules.confirm(fresh.id)
      assert [%{rule: %{"duration_seconds" => 120}}] = Rules.list()
    end

    test "a direct edit makes an outstanding proposal stale" do
      assert {:ok, proposal} = Rules.propose(definition())
      assert {:ok, _} = Rules.save(definition(%{"value" => 62}))
      assert {:error, reason} = Rules.confirm(proposal.id)
      assert reason =~ "changed since"
      assert [%{rule: %{"value" => 62}}] = Rules.list()
    end

    test "save pause resume and delete use the same live house file", %{config: config} do
      agent = Dobby.Jido.whereis(@device)
      assert {:ok, _} = Rules.save(definition())
      assert {:ok, _} = Rules.set_enabled("cold-room", false)
      assert [%{enabled: false}] = Rules.list()
      assert {:ok, _} = Rules.set_enabled("cold-room", true)
      assert [%{enabled: true}] = Rules.list()
      assert {:ok, _} = Rules.delete("cold-room")
      assert Rules.list() == []
      refute File.read!(config.path) =~ "cold-room"
      assert Dobby.Jido.whereis(@device) == agent
      assert HomeConfig.Writer.current(HomeConfig.Writer.server()).house[:rules] == []
      assert Trace.ha_calls() == []
      assert Trace.llm_calls() == []
    end
  end

  test "one continuous breach writes one notice; recovery arms the next occurrence" do
    {watcher, clock, _manifest} = observer()
    :ok = Watcher.check(watcher)
    advance(clock, 59)
    :ok = Watcher.check(watcher)
    assert breaches() == []
    advance(clock, 1)
    :ok = Watcher.check(watcher)
    assert [first] = breaches()
    advance(clock, 120)
    :ok = Watcher.check(watcher)
    assert breaches() == [first]
    assert length(rule_lines()) == 1

    observed(watcher, current: 72)
    assert Repo.get!(Occurrence, first.id).resolved_at != nil
    observed(watcher, current: 66)
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert length(breaches()) == 2
    assert length(rule_lines()) == 2
    assert Trace.ha_calls() == []
    assert Trace.llm_calls() == []
  end

  test "acknowledgment survives watcher restart and recovery allows a new notice" do
    {watcher, clock, manifest} = observer()
    :ok = Watcher.check(watcher)
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert [first] = breaches()

    assert {:ok, %{acknowledged: true}} =
             GenServer.call(
               watcher,
               {:acknowledge, "cold-room", "greg", [expected_occurrence_id: first.id]}
             )

    assert GenServer.call(watcher, :notices) == []
    assert :ok = stop_supervised(Watcher)
    watcher = start_observer(clock, manifest)
    :ok = Watcher.check(watcher)
    advance(clock, 600)
    :ok = Watcher.check(watcher)
    assert length(breaches()) == 1
    assert GenServer.call(watcher, :notices) == []
    assert [row] = Rules.standing(manifest.id)
    assert row.acknowledged_by == "greg"
    observed(watcher, current: 72)
    observed(watcher, current: 66)
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert [%{acknowledged: false}] = GenServer.call(watcher, :notices)
    assert length(breaches()) == 2
  end

  test "an acknowledgment from an old browser cannot silence the next breach" do
    {watcher, clock, _manifest} = observer()
    :ok = Watcher.check(watcher)
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert [first] = breaches()
    observed(watcher, current: 72)
    observed(watcher, current: 66)
    advance(clock, 60)
    :ok = Watcher.check(watcher)

    assert {:error, _} =
             GenServer.call(
               watcher,
               {:acknowledge, "cold-room", "greg", [expected_occurrence_id: first.id]}
             )

    assert [%{id: current_id, acknowledged: false}] = GenServer.call(watcher, :notices)
    refute current_id == first.id

    assert {:ok, %{acknowledged: true}} =
             GenServer.call(
               watcher,
               {:acknowledge, "cold-room", "maya", [expected_occurrence_id: current_id]}
             )

    assert GenServer.call(watcher, :notices) == []
  end

  test "disconnection and restart cannot contribute elapsed observation" do
    {watcher, clock, manifest} = observer()
    :ok = Watcher.check(watcher)
    advance(clock, 50)
    :ok = Fake.set_connection(:reconnecting)
    :ok = Watcher.check(watcher)
    advance(clock, 600)
    :ok = Fake.set_connection(:connected)
    :ok = Watcher.check(watcher)
    assert breaches() == []
    observed(watcher, current: 65)
    advance(clock, 59)
    :ok = Watcher.check(watcher)
    assert breaches() == []
    assert :ok = stop_supervised(Watcher)
    watcher = start_observer(clock, manifest)
    :ok = Watcher.check(watcher)
    advance(clock, 59)
    :ok = Watcher.check(watcher)
    assert breaches() == []
    advance(clock, 1)
    :ok = Watcher.check(watcher)
    assert length(breaches()) == 1
  end

  test "paused and removed definitions ignore stale timer messages" do
    {watcher, clock, manifest} = observer()
    :ok = Watcher.check(watcher)
    generation = :sys.get_state(watcher).generation
    paused = %{manifest | rules: Enum.map(manifest.rules, &%{&1 | enabled: false})}
    assert :ok = GenServer.call(watcher, {:configure, paused, Home.snapshots()})
    advance(clock, 600)
    send(watcher, {:tick, generation})
    :ok = Watcher.check(watcher)
    assert breaches() == []
    assert :ok = GenServer.call(watcher, {:configure, manifest, Home.snapshots()})
    :ok = Watcher.check(watcher)
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert [row] = breaches()
    generation = :sys.get_state(watcher).generation
    assert :ok = GenServer.call(watcher, {:configure, %{manifest | rules: []}, Home.snapshots()})
    send(watcher, {:tick, generation})
    :ok = Watcher.check(watcher)
    assert GenServer.call(watcher, :notices) == []
    assert Repo.get!(Occurrence, row.id).resolved_at != nil
    assert length(breaches()) == 1
  end

  test "absence measures matching recorded changes, not an unchanged snapshot or another attribute" do
    definition =
      definition(%{
        "kind" => "absence",
        "attribute" => "target_temperature_f",
        "operator" => "eq",
        "value" => 70,
        "event_kind" => "device_changed",
        "action" => "state_changed"
      })

    {watcher, clock, _manifest} = observer(definition)
    :ok = Watcher.check(watcher)
    advance(clock, 40)
    observed(watcher, current: 66, target: 70)
    advance(clock, 40)
    # Temperature moved, but there was no new setpoint change to 70.
    observed(watcher, current: 65, target: 70)
    assert breaches() == []
    advance(clock, 20)
    :ok = Watcher.check(watcher)
    assert [row] = breaches()
    assert row.text =~ "no matching change has been recorded"
    assert Trace.ha_calls() == []
    assert Trace.llm_calls() == []
  end

  test "a duplicate recorded event cannot retract a later absence notice" do
    {watcher, clock, _manifest} =
      observer(
        definition(%{
          "kind" => "absence",
          "attribute" => "target_temperature_f",
          "operator" => "eq",
          "value" => 70,
          "event_kind" => "device_changed",
          "action" => "state_changed"
        })
      )

    :ok = Watcher.check(watcher)
    observed(watcher, target: 70)
    event = Dobby.Activity.for_device(@device) |> Enum.find(&(&1.kind == "device_changed"))
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert [notice] = GenServer.call(watcher, :notices)
    send(watcher, {:recorded, event})
    :ok = Watcher.check(watcher)
    assert [^notice] = GenServer.call(watcher, :notices)
    assert length(breaches()) == 1
  end

  test "a restart after all rules were removed resolves old notices" do
    {watcher, clock, manifest} = observer()
    :ok = Watcher.check(watcher)
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert [notice] = GenServer.call(watcher, :notices)
    :ok = stop_supervised(Watcher)
    empty = start_observer(clock, %{manifest | rules: []})
    assert GenServer.call(empty, :notices) == []
    assert Repo.get!(Occurrence, notice.id).resolved_at != nil
    :ok = stop_supervised(Watcher)
    resumed = start_observer(clock, manifest)
    assert GenServer.call(resumed, :notices) == []
  end

  defp definition(changes \\ %{}) do
    Map.merge(
      %{
        "id" => "cold-room",
        "name" => "Cold room",
        "source" => "Tell me if the main room stays below 68 for one minute",
        "device" => @device,
        "kind" => "state",
        "attribute" => "current_temperature_f",
        "operator" => "lt",
        "value" => 68,
        "duration_seconds" => 60
      },
      changes
    )
  end

  defp observer(entry \\ definition()) do
    assert {:ok, rule} = Rule.load(entry, Home.manifest().devices)
    manifest = %{Home.manifest() | rules: [rule]}
    clock = start_supervised!({Agent, fn -> {@now, 0} end})
    {start_observer(clock, manifest), clock, manifest}
  end

  defp start_observer(clock, manifest) do
    start_supervised!(
      {Watcher,
       name: __MODULE__.Observer,
       manifest: manifest,
       snapshots: Home.snapshots(),
       clock: fn -> Agent.get(clock, & &1) end,
       tick_ms: 3_600_000}
    )
  end

  defp advance(clock, seconds) do
    Agent.update(clock, fn {now, mono} -> {DateTime.add(now, seconds), mono + seconds * 1000} end)
  end

  defp observed(watcher, opts) do
    :ok = Fake.inject_state_changed(@entity, thermostat_entity(opts))

    assert_receive %Jido.Signal{type: "dobby.device.state_changed", data: %{device: @device}},
                   2000

    _ = :sys.get_state(Dobby.Jido.whereis(@device))
    settle_watcher!()
    :ok = Watcher.check(watcher)
  end

  defp breaches, do: Repo.all(from(o in Occurrence, order_by: [asc: o.inserted_at, asc: o.id]))

  defp rule_lines,
    do: Enum.filter(Conversation.list_messages(), &(&1.meta["via"] == "standing rule"))
end
