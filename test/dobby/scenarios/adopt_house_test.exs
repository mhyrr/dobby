defmodule Dobby.Scenarios.AdoptHouseTest do
  @moduledoc """
  "Here's what I have — set them all up" (TK-022 layer A).

  The whole-house conversation, run end to end through the real ReAct loop
  with only the model scripted: a person names everything they have in one
  breath, Dobby sweeps discovery once, proposes the lot, presents the
  proposals as one list, somebody says one yes, and every proposal is
  confirmed — with the house restarting exactly once, after the reply.

  ## What this file exists to hold

  **One sweep, one list, one yes.** The batch is doctrine plus the machinery
  layer E already built, deliberately: no plural tools, no new grain. Three
  sequential confirms coalesce because `Dobby.HomeConfig.Writer` keeps one
  `pending_house` slot and `Turn.catch_up/0` releases it once per turn.

  **Proposed is proposed, at any size.** The turn that proposes three devices
  writes no file and moves no house — a list does not dilute the honesty rule
  the single-device arc holds.

  **One restart, and after the reply.** Every confirm defers its restart; the
  writer announces each deferral on `dobby:config` and the single catch-up
  restart the same way. The mailbox order below is a real happens-before:
  local sends complete before the sender continues, and the writer's deferred
  announcements, the thread's reply, and the writer's restart announcement
  are chained by synchronous calls.

  ## The scripting rule

  Same as the single-device arc: `ReActScript` matches by exact string
  equality against the *last* user message, and the house block rides a
  separate message injected by `Dobby.DobbyAgent.RequestTransformer` — so
  `user(Utterance.to_message(utterance))` is the whole match.

  One arithmetic note: DobbyAgent runs with `max_iterations: 5`, and the
  proposing turn spends all five — discover, three proposals, the answer. A
  fourth device in this script would need the request-scoped `:max_iterations`
  option riding along with `react_opts/1`.
  """

  use Dobby.RigCase, async: false

  import Jido.AI.Test

  alias Dobby.ConfigEvents
  alias Dobby.Conversation
  alias Dobby.Conversation.Message
  alias Dobby.Conversation.Turn
  alias Dobby.HomeConfig.Applied
  alias Dobby.HomeConfig.Proposals
  alias Dobby.ThreadEvents
  alias Dobby.Utterance

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  # What Home Assistant already knows and Dobby does not: one of each type
  # the registry can name, which is what "everything I have" comes to today.
  @nest "climate.dining_room"
  @hallway "light.hallway"
  @roomba "vacuum.roomba"

  setup do
    boot_house!([thermostat_device(@thermostat, "main thermostat", entity: @entity)])
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})

    Fake.put_entity(@nest, %{
      state: "heat",
      attributes: %{friendly_name: "Dining Room Nest", current_temperature: 66, temperature: 68}
    })

    Fake.put_entity(@hallway, %{
      state: "on",
      attributes: %{friendly_name: "Hallway Light", supported_color_modes: ["onoff"]}
    })

    Fake.put_entity(@roomba, %{
      state: "docked",
      attributes: %{friendly_name: "Roomba", battery_level: 100}
    })

    config = writable_house!()

    ThreadEvents.subscribe()
    ConfigEvents.subscribe()
    {:ok, speaker} = Conversation.name_speaker("greg")

    Trace.reset()
    %{speaker: speaker, config: config}
  end

  test "the whole house is proposed as one list, adopted on one yes, and restarts once", ctx do
    # -- turn one: the sweep, and one list -----------------------------------
    said =
      Utterance.new(
        "greg",
        "we've got a Nest in the dining room, a hallway light, and the robot vacuum — set them all up"
      )

    proposing =
      expect_react do
        user(Utterance.to_message(said))

        call("discover_entities", %{})

        call("propose_device", %{
          "id" => "thermostat:dining_room",
          "type" => "thermostat",
          "name" => "dining room thermostat",
          "entity_id" => @nest
        })

        call("propose_device", %{
          "id" => "light:hallway",
          "type" => "light",
          "name" => "hallway light",
          "entity_id" => @hallway
        })

        call("propose_device", %{
          "id" => "vacuum:roomba",
          "type" => "vacuum",
          "name" => "the robot vacuum",
          "entity_id" => @roomba
        })

        answer("""
        Here's everything I can see that you named — proposed, not added yet:
        1. dining room thermostat on climate.dining_room
        2. hallway light on light.hallway
        3. the robot vacuum on vacuum.roomba
        Say yes and I'll add all three.\
        """)
      end

    Turn.run(said, ctx.speaker, react_opts(proposing))

    assert_receive {:replied, %Message{role: :assistant, text: proposed_text}}

    # One list, ids and all — and it says proposed, not done.
    for line <- ["1. dining room thermostat", "2. hallway light", "3. the robot vacuum"] do
      assert proposed_text =~ line
    end

    assert proposed_text =~ "not added yet"

    # One sweep, then the lot: discovery ran once, and every match got a row.
    assert Trace.tool_calls() ==
             ["discover_entities", "propose_device", "propose_device", "propose_device"]

    assert [nest, hallway, roomba] = Proposals.outstanding()
    assert nest.device_id == "thermostat:dining_room"
    assert hallway.device_id == "light:hallway"
    assert roomba.device_id == "vacuum:roomba"
    assert Enum.all?([nest, hallway, roomba], &(&1.proposed_by == "greg"))

    # Three proposals and the house did not move an inch.
    assert Enum.map(Dobby.Home.devices(), & &1.id) == [@thermostat]

    written = File.read!(ctx.config.path)
    refute written =~ "dining_room"
    refute written =~ "hallway"
    refute written =~ "roomba"

    assert Trace.ha_calls() == []

    # -- the box reboots between the two ------------------------------------
    #
    # The property the rows exist for, same as the single-device arc: a list
    # proposed before dinner survives the house restarting and is still what
    # "yes" resolves to. It is also what makes the second scripted turn
    # possible at all in the replay tier — `ReActScript` indexes its turns by
    # counting assistant tool-call messages in the live context, and
    # rehydration hands the next turn a conversation of plain text.
    {:ok, _pid} = Dobby.Home.restart()

    assert [^nest, ^hallway, ^roomba] = Proposals.outstanding()

    # -- turn two: one yes ---------------------------------------------------
    Trace.reset()
    agreed = Utterance.new("greg", "yes — add all three")

    confirming =
      expect_react do
        user(Utterance.to_message(agreed))
        call("confirm_device", %{"id" => nest.id})
        call("confirm_device", %{"id" => hallway.id})
        call("confirm_device", %{"id" => roomba.id})

        answer("""
        Done — the dining room thermostat, the hallway light and the robot \
        vacuum are all part of the house now.\
        """)
      end

    Turn.run(agreed, ctx.speaker, react_opts(confirming))

    # The yes confirmed each proposal, and nothing was re-proposed.
    assert Trace.tool_calls() == ["confirm_device", "confirm_device", "confirm_device"]

    # Exactly one restart, and only after the reply was in the thread. The
    # writer announces every deferral and the one catch-up on `dobby:config`,
    # so the mailbox tells the whole story in order: three saves that each
    # held their restart, the reply, then the single restart that took them
    # all on at once.
    assert [
             {:applied, :deferred},
             {:applied, :deferred},
             {:applied, :deferred},
             {:replied, applied_text},
             {:applied, :restarted}
           ] = drain_arc()

    assert applied_text =~ "all part of the house now"

    # The file is the record, and it now carries all three.
    written = File.read!(ctx.config.path)

    for fragment <- [
          "thermostat:dining_room",
          @nest,
          "light:hallway",
          @hallway,
          "vacuum:roomba",
          @roomba
        ] do
      assert written =~ fragment
    end

    # Every proposal accounted for: applied, by the person who said yes.
    for proposal <- [nest, hallway, roomba] do
      assert {:ok, stored} = Proposals.fetch(proposal.id)
      assert stored.status == :applied
      assert stored.confirmed_by == "greg"
    end

    assert Proposals.outstanding() == []

    # And the house came back up once, with all four aboard.
    ids = Enum.map(Dobby.Home.devices(), & &1.id)

    assert Enum.sort(ids) ==
             Enum.sort([@thermostat, "thermostat:dining_room", "light:hallway", "vacuum:roomba"])

    for id <- ["thermostat:dining_room", "light:hallway", "vacuum:roomba"] do
      assert is_pid(Dobby.Jido.whereis(id))
    end
  end

  # The replied line and every `dobby:config` announcement, in arrival order.
  # Arrival order is causal order here — every send in the chain is local and
  # synchronous — which is what lets a list literal assert "the restart came
  # after the reply" rather than merely "a restart happened".
  defp drain_arc(acc \\ []) do
    receive do
      {:replied, %Message{role: :assistant, text: text}} ->
        drain_arc([{:replied, text} | acc])

      {:applied, %Applied{applied: [], on_restart: [:house]}} ->
        drain_arc([{:applied, :deferred} | acc])

      {:applied, %Applied{applied: [:house]}} ->
        drain_arc([{:applied, :restarted} | acc])

      _other ->
        drain_arc(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
