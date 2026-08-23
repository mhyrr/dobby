defmodule Dobby.Conversation.TurnTest do
  @moduledoc """
  One request, from what somebody said to what Dobby answered.

  Run against the real house and the real ReAct loop with only the model
  scripted, which is the rig's whole thesis: the thing under test here is the
  translation from jido's runtime events into a thread a person reads, and
  that translation is only worth testing against events the runtime actually
  emits.

  **The replay tier emits no deltas.** A scripted turn goes through
  `consume_generate` and never enters the streaming path, so `:llm_delta`
  never fires here. That is not a gap in these tests — it is the seam between
  the tiers. Delta *handling* is tested at the surface, where the LiveView is
  fed the events `Dobby.ThreadEvents` promises; delta *emission* is measured
  in `Dobby.Eval.StreamingEvalTest` against a real model.
  """

  use Dobby.RigCase, async: false

  import Jido.AI.Test

  alias Dobby.Activity
  alias Dobby.Conversation
  alias Dobby.Conversation.Message
  alias Dobby.Conversation.Turn
  alias Dobby.ThreadEvents
  alias Dobby.Utterance

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  setup do
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})
    ThreadEvents.subscribe()

    {:ok, speaker} = Conversation.name_speaker("greg")

    Trace.reset()
    %{speaker: speaker}
  end

  test "an actuating turn reaches the thread as words, steps, and a reply", %{speaker: speaker} do
    utterance = Utterance.new("greg", "Dobby, turn the thermostat to 70")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_set_temperature", %{"device" => @thermostat, "temperature_f" => 70})
        answer("Set the main thermostat to 70°.")
      end

    Turn.run(utterance, speaker, react_opts(script))

    # The utterance is in the thread before the model has said anything, so a
    # slow request shows the person their own words rather than nothing.
    assert_receive {:said, %Message{role: :user, text: "Dobby, turn the thermostat to 70"}}
    assert_receive {:turn_started, request_id}

    # The step is in device language, not tool language. Nobody in a house
    # reads `thermostat_set_temperature`.
    assert_receive {:step, ^request_id, %{label: "setting the main thermostat", state: :running}}
    assert_receive {:step, ^request_id, %{label: "setting the main thermostat", state: :done}}

    assert_receive {:replied, %Message{role: :assistant, text: "Set the main thermostat to 70°."}}
  end

  test "a tool call that moved the house leaves the same line a card would",
       %{speaker: speaker} do
    utterance = Utterance.new("greg", "Dobby, turn the thermostat to 71")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_set_temperature", %{"device" => @thermostat, "temperature_f" => 71})
        answer("Set to 71.")
      end

    Turn.run(utterance, speaker, react_opts(script))

    # The reply says what Dobby did in his own words; this is the record, and
    # it is the same shape a card tap or a schedule writes — so scrolling back
    # to yesterday shows one kind of entry for "the thermostat went to 71",
    # however it got there.
    assert_receive {:turn_started, request_id}

    assert_receive {:system_line,
                    %Message{
                      role: :system,
                      text: "main thermostat",
                      request_id: ^request_id,
                      meta: meta
                    }}

    assert meta["via"] == "greg"
    assert meta["word"] == "Set"
    assert meta["value"] == "71°"
  end

  test "a library write renders its record line from the tool result alone", %{speaker: speaker} do
    # The library's write tools carry no number the way the thermostat's does —
    # a lock's result says `lock_state: :locked` and nothing else. This is the
    # wiring proof for that whole family: the result shape `library_test`
    # guards actually reaches `Interventions.reading/1` through a real ReAct
    # turn and comes out as a word, attributed to the speaker.
    seed_house(%{"lock.front_door" => %{state: "unlocked", attributes: %{}}})

    utterance = Utterance.new("greg", "Dobby, lock the front door")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("lock_secure", %{"device" => "lock:front"})
        answer("Told the front door lock to secure.")
      end

    Turn.run(utterance, speaker, react_opts(script))

    assert_receive {:turn_started, request_id}

    assert_receive {:system_line,
                    %Message{
                      role: :system,
                      text: "front door lock",
                      request_id: ^request_id,
                      meta: meta
                    }}

    assert meta["device"] == "lock:front"
    assert meta["via"] == "greg"
    assert meta["word"] == "Set"
    assert meta["value"] == "Locked"
  end

  # `Turn.run/3` everywhere else in this file skips the queue deliberately, so
  # that a test can assert against a finished turn. This one goes through the
  # front door — `say/3` casts to `Turn.Queue`, which records the utterance and
  # runs the real `Turn.answer/4`. It is what makes the queue's own tests
  # honest: they inject a runner to observe ordering, and this proves the
  # production runner reaches the model through the same door.
  test "say/3 goes through the queue and still answers", %{speaker: speaker} do
    utterance = Utterance.new("greg", "how warm is it?")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_get_status", %{"device" => @thermostat})
        answer("68° in here.")
      end

    assert :ok = Turn.say(utterance, speaker, react_opts(script))

    assert_receive {:said, %Message{role: :user, text: "how warm is it?"}}, 2_000
    assert_receive {:replied, %Message{role: :assistant, text: "68° in here."}}, 5_000
  end

  test "a tool call that only read something announces nothing", %{speaker: speaker} do
    utterance = Utterance.new("greg", "how warm is it?")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_get_status", %{"device" => @thermostat})
        answer("68° in here.")
      end

    Turn.run(utterance, speaker, react_opts(script))

    assert_receive {:replied, %Message{role: :assistant}}

    # Keyed on the write-acknowledgment protocol's own `accepted: true` rather
    # than on a list of tool names, so a reading tool cannot accidentally
    # announce an intervention.
    refute_receive {:system_line, _message}, 200
  end

  test "the reply carries its own record of the work", %{speaker: speaker} do
    utterance = Utterance.new("greg", "how warm is it?")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_get_status", %{"device" => @thermostat})
        answer("68° in here.")
      end

    Turn.run(utterance, speaker, react_opts(script))

    assert %Message{role: :assistant, meta: meta, request_id: request_id} =
             Conversation.list_messages() |> List.last()

    # Persisted rather than held in a LiveView: scrolling back to yesterday
    # should still show what Dobby did, which is what makes the answer
    # trustworthy a week later.
    assert [%{"label" => "reading the main thermostat", "state" => "done"}] = meta["steps"]
    assert is_integer(meta["duration_ms"])

    # And one request id ties the utterance, the reply, and the log together.
    assert request_id
    assert [%Message{request_id: ^request_id} | _] = Conversation.list_messages()
    assert [_tool, _request] = Activity.for_request(request_id) |> Enum.sort_by(& &1.kind)
  end

  test "a device that declines is HELD, and says why", %{speaker: speaker} do
    utterance = Utterance.new("greg", "set it to 85")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_set_temperature", %{"device" => @thermostat, "temperature_f" => 85})
        answer("It wouldn't — 85 is above its limit.")
      end

    Turn.run(utterance, speaker, react_opts(script))

    assert_receive {:step, _request_id, %{state: :held, detail: detail}}
    assert detail =~ "76"

    # HELD is a fact about the thermostat, not a failure of Dobby's: the reply
    # still lands and the thread still reads as a conversation.
    assert_receive {:replied, %Message{role: :assistant}}
    assert Fake.trace() == []
  end

  test "a request that fails says so in the thread", %{speaker: speaker} do
    # Nothing scripted, and the replay tier's base_url is a closed port — so
    # this is a real failure of a real request rather than a stubbed one.
    utterance = Utterance.new("greg", "nobody scripted this")

    Turn.run(utterance, speaker, timeout: 5_000)

    assert_receive {:said, %Message{role: :user}}

    # The failure is a line, not a silence. A surface that shows an utterance
    # and then nothing leaves a person unable to tell whether Dobby is slow,
    # broken, or ignoring them.
    assert_receive {:system_line, %Message{role: :system, meta: meta}}, 10_000
    assert meta["kind"] == "request_failed"
  end

  test "the activity log records the tool call, whatever the thread showed", %{speaker: speaker} do
    utterance = Utterance.new("greg", "Dobby, turn the thermostat to 71")

    script =
      expect_react do
        user(Utterance.to_message(utterance))
        call("thermostat_set_temperature", %{"device" => @thermostat, "temperature_f" => 71})
        answer("Set to 71.")
      end

    Turn.run(utterance, speaker, react_opts(script))

    assert [entry] = Activity.recent() |> Enum.filter(&(&1.kind == "tool_call"))
    assert entry.actor == "greg"
    assert entry.device == @thermostat
    assert entry.action == "thermostat_set_temperature"
    assert entry.args["temperature_f"] == 71

    # The tool's own return is a tagged tuple, which JSON has no word for. A
    # log write that raised on it would take down the turn it was only meant
    # to describe.
    assert entry.result["state"] == "done"

    assert ["ok", %{"accepted" => true, "device" => @thermostat}, _directives] =
             entry.result["value"]
  end
end
