defmodule Dobby.Eval.RehydrationEvalTest do
  @moduledoc """
  Whether Dobby remembers the morning after a restart (design §10.8).

      DOBBY_EVAL=1 mix test --only eval

  `Dobby.Conversation.RehydrateTest` already proves the seam: rows go in, a
  `Jido.AI.Context` comes out, and `to_messages/1` projects it in the right
  order. What that cannot prove is the thing rehydration exists for — that the
  model *uses* it. A context can be built perfectly and handed over correctly
  and still not resolve a pronoun, and the only way to find out is to ask one.

  So the question asked after the restart names no device and no number, and
  the number it needs exists in exactly one place: something the household said
  before the restart. The `<house>` block cannot supply it — that block says
  what the setpoint is *now*, which is the wrong answer by construction.

  ## What the first attempt found

  The first version asked "put it back to what it was before" and the model
  said: *"I don't know what the previous setting was — this conversation only
  shows the thermostat being set to 72."* Which is rehydration working, and a
  badly written test: the transcript recorded the new value and never the old
  one, so there was nothing to resolve against. The reply is also doctrine
  holding under pressure — asked to restore a value it had never been told, the
  model refused rather than guessing a plausible one.

  The question below therefore states the number it will be asked for later,
  the way a person would, and never states it again.

  ## Why the restart is a real one

  The house is rebooted through `Dobby.Home`, which is what editing the
  manifest does in production (§2.4). Nothing reaches around the bootstrap to
  place a context by hand: the point is that `Home.init/1` reads the rows and
  builds the agent, and a test that skipped that would be testing this file.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Conversation
  alias Dobby.Conversation.Turn
  alias Dobby.Utterance

  @moduletag :eval
  @moduletag timeout: 240_000

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  setup do
    seed_house(%{@entity => thermostat_entity(current: 66, target: 68)})
    {:ok, speaker} = Conversation.name_speaker("greg")

    %{speaker: speaker}
  end

  test "resolves a pronoun against a turn from before the restart", %{speaker: speaker} do
    # This morning. A real turn, through the real streaming path, so what gets
    # rehydrated is what a household actually leaves behind. 68 is said once,
    # here, and never again.
    say!(speaker, "Dobby, put the main thermostat up to 72 — 68 is normally fine, I'm just cold")

    assert eventually(fn -> agent_state(@thermostat).target_temperature_f == 72.0 end)
    assert [_utterance, _reply | _] = Conversation.recent_dialogue(10)

    # The restart. Everything the process knew is gone; only the rows survive.
    restart_house!()
    Trace.reset()

    # "it" is the thermostat and "normal" is 68. Neither is anywhere but the
    # transcript: the <house> block says the setpoint is 72, which is precisely
    # the wrong answer, and the roster says nothing about what anyone prefers.
    say!(speaker, "I've warmed up — put it back to normal")

    Dobby.Eval.report("after a restart", last_reply())
    Dobby.Eval.assert_within_policy()

    assert eventually(fn -> agent_state(@thermostat).target_temperature_f == 68.0 end),
           "the setpoint is #{inspect(agent_state(@thermostat).target_temperature_f)}, " <>
             "so the pre-restart turn did not reach the model"
  end

  # Through `Turn`, not `DobbyAgent.say/2`, because `Turn` is what writes the
  # transcript — and the transcript is the whole subject here. A test that
  # asked the agent directly would have to seed the rows itself, which is the
  # fixture lying about what production builds.
  defp say!(speaker, text) do
    Turn.run(Utterance.new(speaker.name, text), speaker, llm_opts: Dobby.Eval.llm_opts())
  end

  defp last_reply do
    Conversation.recent_dialogue(1) |> List.first() |> then(& &1.text)
  end

  defp restart_house! do
    stop_home!()
    {:ok, _pid} = Supervisor.restart_child(Dobby.Supervisor, Dobby.Home)

    Fake.subscribe()
    Dobby.DeviceEvents.subscribe()
    seed_house(%{@entity => thermostat_entity(current: 66, target: 72)})

    :ok
  end
end
