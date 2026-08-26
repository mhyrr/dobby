# TK-008's repro harness. The module is only defined when somebody asks for it,
# because the question it answers is a rate rather than a pass or a fail: run the
# same actuating turn a few hundred times and count how often the tool call's
# arguments have not arrived by the time its result has. One run of a race proves
# nothing either way, and a case that fails two percent of the time is a worse
# thing to own than the bug it describes. So `mix test` compiles nothing here.
#
#     REPRO_RUNS=300 mix test test/dobby/conversation/turn_ordering_repro_test.exs
#     REPRO_RUNS=300 REPRO_LOAD=8 mix test test/dobby/conversation/turn_ordering_repro_test.exs
#
if System.get_env("REPRO_RUNS") not in [nil, ""] do
  defmodule Dobby.Conversation.TurnOrderingReproTest do
    @moduledoc """
    The harness that reproduced TK-008, kept so the fix can be shown to close it.

    ## The rate, and why it needs a busy box

    Before the fix the failure showed 5 times in 150 runs while the machine was
    loaded, 5 times in 200 with `REPRO_LOAD=8`, and not once in 300 runs while
    the machine was quiet — which is the same thing the ticket saw when it only
    ever appeared under whole-suite load. `REPRO_LOAD` spawns that many spinning
    processes for the length of each scenario, to supply that load on purpose.

    ## Why one turn per case rather than a loop inside one

    The scripted ReAct path chooses which scripted turn to answer with by
    counting assistant-with-tool_calls messages across the whole agent context
    (`Jido.AI.Test.ReActScript.consumed_tool_turns/1`). A second scripted turn
    inside one scenario therefore starts at index 1 and answers without calling
    the tool at all. A case per turn gets a fresh thread and an agent that
    rehydrated from it, which is the only way to run the *same* first turn twice.

    ## What it asserts, and why both halves

    `:tool_started` carries the arguments and `:tool_completed` carries the
    result, and they reach the turn as two separate `send/2`s from two separately
    spawned tasks (`Jido.Agent.Directive.Emit` dispatches through
    `Task.Supervisor.start_child/2`), so there is no happens-before between them.
    When they land in the wrong order it shows twice over: the activity row
    records a tool call against no device, and the step the board is showing goes
    backwards from done to running. One cause, so one assertion — a run that
    reported only the nil device would hide half of what broke.

    Both halves are outcomes, not orderings. The race is still there after the
    fix and always will be; what changed is that the fold absorbs it. A
    disordered turn now publishes `done`, then `done` again under the better
    label the arguments make, and that is a pass. Asserting the events arrived
    as `running, done` would only be counting the scheduler's coin flips.
    """

    use Dobby.RigCase, async: false

    import Jido.AI.Test

    alias Dobby.Activity
    alias Dobby.Conversation
    alias Dobby.Conversation.Turn
    alias Dobby.ThreadEvents
    alias Dobby.Utterance

    @entity "climate.main_floor"

    @runs String.to_integer(System.get_env("REPRO_RUNS", "0"))
    @load String.to_integer(System.get_env("REPRO_LOAD", "0"))

    setup do
      seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})
      ThreadEvents.subscribe()

      {:ok, speaker} = Conversation.name_speaker("greg")

      busy = for _ <- 1..@load//1, do: spawn(fn -> spin() end)
      on_exit(fn -> Enum.each(busy, &Process.exit(&1, :kill)) end)

      Trace.reset()
      %{speaker: speaker}
    end

    for run <- 1..@runs//1 do
      test "run #{run}: the tool call's arguments are known by the time its result is",
           %{speaker: speaker} do
        utterance = Utterance.new("greg", "Dobby, turn the thermostat to 71")

        script =
          expect_react do
            user(Utterance.to_message(utterance))

            call("thermostat_set_temperature", %{
              "device" => "thermostat:main",
              "temperature_f" => 71
            })

            answer("Set to 71.")
          end

        Turn.run(utterance, speaker, react_opts(script))

        assert_receive {:step, _request_id, %{state: _first}}, 5_000
        assert_receive {:step, _request_id, %{state: last}}, 5_000

        assert [entry] = Activity.recent() |> Enum.filter(&(&1.kind == "tool_call"))

        # Not the arrival order — no fix can change that, and asserting it
        # would only count how often the scheduler swapped two sends. What is
        # asserted is what the swap used to cost: the word the step comes to
        # rest on, and whether the row knows what it moved. Both as one tuple,
        # so a failure prints them together.
        assert {:done, "thermostat:main"} == {last, entry.device}
      end
    end

    defp spin do
      Enum.reduce(1..20_000, 0, fn i, acc -> acc + rem(i, 7) end)
      spin()
    end
  end
end
