defmodule Dobby.RulesRuntimeTest do
  @moduledoc """
  Standing intentions through the real writer, database, and Fake HA boundary.
  Only elapsed time is supplied by the test; observations still travel through
  device agents and the production activity writer.
  """
  use Dobby.RigCase, async: false
  import Ecto.Query
  import ExUnit.CaptureLog
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

    # Review of 2026-09-07: a proposal whose id a standing rule already holds
    # is an edit, and confirming it replaces that rule and its watch. The
    # machinery always allowed that and said nothing, so the household agreed
    # to the new rule alone. The tool now names what it would replace.
    test "a proposal that would replace a standing rule says so" do
      assert {:ok, _} = Rules.save(definition())
      assert [%{id: id, description: standing}] = Rules.list()

      # Atom keys, as Jido hands a tool its validated params.
      params = %{
        id: id,
        name: "Cold room, an hour",
        device: @device,
        kind: "state",
        attribute: "current_temperature_f",
        operator: "lt",
        number_value: 60,
        duration: 60,
        duration_unit: "minutes"
      }

      context = %{speaker: "greg", via: :conversation, request_id: "turn-9"}
      assert {:ok, described} = Jido.Exec.run(Dobby.Tools.ProposeRule, params, context)

      assert described.replaces.id == id
      assert described.replaces.description == standing
      assert described.replaces.note =~ "replaces that rule"

      # A fresh id replaces nothing and says nothing about it.
      assert {:ok, fresh} =
               Jido.Exec.run(
                 Dobby.Tools.ProposeRule,
                 %{params | id: "cold-room-hour"},
                 context
               )

      refute Map.has_key?(fresh, :replaces)
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

  test "a rule saved into the house file is watched by the house's own watcher" do
    # No test-owned watcher here, and no injected clock. This is the seam the
    # rest of the file stubs out: the writer, `Home.apply_rules`, and the
    # `Dobby.Rules.Watcher` the application supervisor started.
    writable_house!()

    # 62 arrives the way every reading does — HA, the client, the device agent
    # — so the watcher gets the house's own snapshot, not the test's.
    :ok = Fake.inject_state_changed(@entity, thermostat_entity(current: 62))

    assert_receive %Jido.Signal{type: "dobby.device.state_changed", data: %{device: @device}},
                   2000

    _ = :sys.get_state(Dobby.Jido.whereis(@device))

    assert {:ok, _} = Rules.save(definition(%{"duration_seconds" => 0}))

    # `Rules.save` already ran the writer through `Home.apply_rules`, so the
    # watcher holds the rule. `check` is the barrier, not the trigger.
    :ok = Watcher.check()

    assert [%{rule_id: "cold-room", name: "Cold room", acknowledged: false}] = Rules.notices()
    assert [line] = rule_lines()
    assert line.meta["rule_id"] == "cold-room"
    assert line.text =~ "This has held since"
    assert length(breaches()) == 1
    refute_received {:ha_call, _}
    assert Trace.ha_calls() == []
    assert Trace.llm_calls() == []
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

  test "a reconnect rereads the house, so a device that never moved is still watched" do
    {watcher, clock, _manifest} = observer()
    :ok = Watcher.check(watcher)
    advance(clock, 30)
    :ok = Watcher.check(watcher)
    assert breaches() == []

    :ok = Fake.set_connection(:reconnecting)
    :ok = Watcher.check(watcher)
    :ok = Fake.set_connection(:connected)
    # Nothing is injected after the reconnect, and that is the whole point: the
    # resync that follows one is silent for a device that did not move. A
    # watcher that emptied its readings here would read the room as unknown
    # until the thermostat physically changed, and this notice would never
    # arrive at all.
    :ok = Watcher.check(watcher)

    # Elapsed time still restarts at the reconnect. The thirty seconds before
    # the drop were not observed by anybody, so they do not count: at 59 there
    # is nothing, and the notice lands at 60 measured from the reconnect.
    advance(clock, 59)
    :ok = Watcher.check(watcher)
    assert breaches() == []
    advance(clock, 1)
    :ok = Watcher.check(watcher)
    assert [%{rule_id: "cold-room"}] = breaches()
  end

  test "a timer from before an edit cannot start the new definition's clock early" do
    {watcher, clock, manifest} = observer()
    :ok = Watcher.check(watcher)
    stale = :sys.get_state(watcher).generation

    # The same id, loaded the way an edit through the house file loads.
    assert {:ok, replacement} =
             Rule.load(
               definition(%{"name" => "Chilly room", "value" => 67}),
               Home.manifest().devices
             )

    edited = %{manifest | rules: [replacement]}
    assert :ok = GenServer.call(watcher, {:configure, edited, Home.snapshots()})

    # Past the old definition's minute, which the edit already discarded.
    advance(clock, 100)
    send(watcher, {:tick, stale})
    _ = :sys.get_state(watcher)
    assert breaches() == []

    # The new definition's first observation belongs to its first real
    # evaluation, thirty seconds later — not to the stale tick above. A watcher
    # that acted on that tick would be measuring from t+100 and would announce
    # this breach here, half a minute early.
    advance(clock, 30)
    :ok = Watcher.check(watcher)
    advance(clock, 45)
    :ok = Watcher.check(watcher)
    assert breaches() == []

    advance(clock, 15)
    :ok = Watcher.check(watcher)
    assert [row] = breaches()
    assert row.name == "Chilly room"
    assert row.observed_since == DateTime.add(@now, 130)
  end

  test "a paused definition stops watching, and removing it resolves what it said" do
    {watcher, clock, manifest} = observer()
    :ok = Watcher.check(watcher)
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert [row] = breaches()

    paused = %{manifest | rules: Enum.map(manifest.rules, &%{&1 | enabled: false})}
    assert :ok = GenServer.call(watcher, {:configure, paused, Home.snapshots()})
    :ok = Watcher.check(watcher)
    assert Repo.get!(Occurrence, row.id).resolved_at != nil
    advance(clock, 600)
    :ok = Watcher.check(watcher)
    assert length(breaches()) == 1

    assert :ok = GenServer.call(watcher, {:configure, %{manifest | rules: []}, Home.snapshots()})
    :ok = Watcher.check(watcher)
    assert GenServer.call(watcher, :notices) == []
    assert length(breaches()) == 1
  end

  test "a standing occurrence this watcher never wrote is adopted, not repeated" do
    {watcher, clock, manifest} = observer()
    :ok = Watcher.check(watcher)
    [rule] = manifest.rules

    # Inserted straight into the database because that is where it comes from:
    # a second watcher on the same house, or this one crashing between the
    # commit and its own bookkeeping. Either way the household has already been
    # told, and the row is the evidence of it.
    {:ok, standing} =
      Repo.insert(%Occurrence{
        house_id: manifest.id,
        rule_id: rule.id,
        revision: Rules.revision(rule),
        name: rule.name,
        text: "Cold room: another watcher already said this.",
        observed_since: @now
      })

    advance(clock, 60)
    log = capture_log(fn -> :ok = Watcher.check(watcher) end)

    refute log =~ "could not evaluate rule"
    assert rule_lines() == []
    assert [%{id: adopted}] = GenServer.call(watcher, :notices)
    assert adopted == standing.id
    assert Enum.map(breaches(), & &1.id) == [standing.id]

    # And it stays adopted: the next pass has nothing left to say either.
    advance(clock, 120)
    :ok = Watcher.check(watcher)
    assert rule_lines() == []
    assert Enum.map(breaches(), & &1.id) == [standing.id]
  end

  test "a watch window closes on its own notice and lends no time to the next day" do
    # @now is noon in the house's timezone, so the rule is watching from its
    # first instant and the window shuts an hour later.
    {watcher, clock, _manifest} =
      observer(
        definition(%{
          "window" => %{"start" => "12:00", "end" => "13:00"},
          "duration_seconds" => 60
        })
      )

    :ok = Watcher.check(watcher)
    advance(clock, 60)
    :ok = Watcher.check(watcher)
    assert [first] = breaches()
    assert first.observed_since == @now

    # 13:00 local: the window is closed, so the house stops watching and the
    # notice it was carrying is resolved rather than left standing overnight.
    advance(clock, 3540)
    :ok = Watcher.check(watcher)
    assert Repo.get!(Occurrence, first.id).resolved_at != nil
    assert GenServer.call(watcher, :notices) == []
    assert [_] = resolutions("cold-room")

    # Noon the next day. The condition never stopped holding, but the fifty-nine
    # minutes it held inside yesterday's window are not observation this window
    # can spend: the new one starts its own minute from scratch.
    advance(clock, 82_800)
    :ok = Watcher.check(watcher)
    assert length(breaches()) == 1
    advance(clock, 59)
    :ok = Watcher.check(watcher)
    assert length(breaches()) == 1

    advance(clock, 1)
    :ok = Watcher.check(watcher)
    assert [_, second] = breaches()
    assert second.observed_since == DateTime.add(@now, 86_400)
  end

  test "an unavailable thermostat breaks the interval, which restarts when it answers again" do
    {watcher, clock, _manifest} = observer()
    :ok = Watcher.check(watcher)
    advance(clock, 30)

    # Unknown is not evidence the room was cold; it is evidence of nothing.
    injected(watcher, %{state: "unavailable", attributes: %{}})
    advance(clock, 600)
    :ok = Watcher.check(watcher)
    assert breaches() == []

    observed(watcher, current: 66)
    advance(clock, 59)
    :ok = Watcher.check(watcher)
    assert breaches() == []

    advance(clock, 1)
    :ok = Watcher.check(watcher)
    assert [row] = breaches()
    # Measured from the reading that came back, not from the first cold one.
    assert row.observed_since == DateTime.add(@now, 630)
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

  test "an absence rule measures its silence from the reconnect, not from before the drop" do
    {watcher, clock, _manifest} = observer(absence_definition())
    :ok = Watcher.check(watcher)
    advance(clock, 30)
    :ok = Watcher.check(watcher)

    # Nobody was listening for a setpoint change while the connection was down,
    # so the silence during it is not evidence that nothing changed.
    :ok = Fake.set_connection(:reconnecting)
    :ok = Watcher.check(watcher)
    :ok = Fake.set_connection(:connected)
    :ok = Watcher.check(watcher)

    # The old deadline falls here and nothing is said.
    advance(clock, 59)
    :ok = Watcher.check(watcher)
    assert breaches() == []

    advance(clock, 1)
    :ok = Watcher.check(watcher)
    assert [row] = breaches()
    assert row.text =~ "no matching change has been recorded"
    assert row.observed_since == DateTime.add(@now, 30)
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

  defp absence_definition(changes \\ %{}) do
    definition(
      Map.merge(
        %{
          "kind" => "absence",
          "attribute" => "target_temperature_f",
          "operator" => "eq",
          "value" => 70,
          "event_kind" => "device_changed",
          "action" => "state_changed"
        },
        changes
      )
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

  defp observed(watcher, opts), do: injected(watcher, thermostat_entity(opts))

  defp injected(watcher, entity) do
    :ok = Fake.inject_state_changed(@entity, entity)

    assert_receive %Jido.Signal{type: "dobby.device.state_changed", data: %{device: @device}},
                   2000

    _ = :sys.get_state(Dobby.Jido.whereis(@device))
    settle_watcher!()
    :ok = Watcher.check(watcher)
  end

  defp breaches, do: Repo.all(from(o in Occurrence, order_by: [asc: o.inserted_at, asc: o.id]))

  defp resolutions(rule_id) do
    Enum.filter(
      Dobby.Activity.recent(200),
      &(&1.kind == "rule_resolved" and &1.action == rule_id)
    )
  end

  defp rule_lines,
    do: Enum.filter(Conversation.list_messages(), &(&1.meta["via"] == "standing rule"))
end
