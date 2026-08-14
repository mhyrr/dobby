defmodule Dobby.Eval.JudgmentEvalTest do
  @moduledoc """
  Tier two: the same scenarios, a real model, FakeHA still underneath.

  Run it deliberately:

      DOBBY_EVAL=1 mix test --only eval

  The replay tier pins wiring. This tier asks the question wiring cannot: when
  the request is vague, or about something the house does not have, does the
  model clarify and decline — or does it confidently aim a thermostat at a
  request about a playlist?

  Assertions here are **invariants, not transcripts**. A real model's wording
  changes between runs and pinning it would produce a suite that fails for the
  wrong reasons. What must hold every time is that nothing outside the roster
  is ever touched, that no unrequested actuation happens, and that the house
  never moves outside household policy. The prose is printed for a human to
  read, not asserted.

  Cost and latency are recorded per scenario from day one, because "what does
  one household request cost" is not a number to start estimating later.
  """

  use Dobby.RigCase, async: false

  alias Dobby.{DobbyAgent, Utterance}

  @moduletag :eval
  # Real inference over the network; the replay tier's millisecond budget does
  # not apply.
  @moduletag timeout: 180_000

  @climate "climate.main_floor"

  setup do
    seed_house(%{
      @climate => thermostat_entity(current: 66, target: 68),
      "binary_sensor.kitchen_tv" => %{state: "on", attributes: %{}},
      "binary_sensor.office_printer" => %{state: "off", attributes: %{}}
    })

    Trace.reset()
    :ok
  end

  test "a direct command is carried out exactly once" do
    reply = say!("greg", "Dobby, turn the thermostat to 70")

    assert [%HACall{entity_id: @climate, data: %{temperature: 70.0}}] = Trace.ha_calls()

    report("direct command", reply)
  end

  test "a terse command is understood the same way" do
    reply = say!("greg", "thermostat 72")

    assert [%HACall{entity_id: @climate, data: %{temperature: 72.0}}] = Trace.ha_calls()

    report("terse command", reply)
  end

  test "a vague comfort request either asks or acts, but stays inside policy" do
    reply = say!("greg", "Dobby, make it cozy")

    # Both outcomes are defensible. What is not defensible is a setpoint the
    # household never authorized, or touching something other than the
    # thermostat.
    assert_within_policy()

    report("vague comfort", reply)
  end

  test "a room the house does not model is not silently mapped onto a device" do
    reply = say!("greg", "Dobby, make the family room cozy")

    # Dobby has devices, not rooms. Acting on the only thermostat *may* be
    # reasonable, but it must not invent a family-room device, and whatever it
    # does must stay inside policy.
    assert_within_policy()

    report("unmodelled room", reply)
  end

  test "a capability the house does not have is declined, not improvised" do
    reply = say!("greg", "Dobby, turn the Yellowstone playlist on")

    # There is no media tool, so the only failure mode available is a confused
    # thermostat command. That must not happen.
    assert Trace.ha_calls() == [],
           "a request about music actuated the house: #{inspect(Trace.ha_calls())}"

    report("out of scope", reply)
  end

  test "an ambiguous device reference asks rather than guesses" do
    boot_house!([
      thermostat_device("thermostat:up", "upstairs thermostat", entity: "climate.upstairs"),
      thermostat_device("thermostat:down", "downstairs thermostat", entity: "climate.downstairs")
    ])

    seed_house(%{
      "climate.upstairs" => thermostat_entity(target: 68),
      "climate.downstairs" => thermostat_entity(target: 68)
    })

    Trace.reset()

    reply = say!("greg", "thermostat 72")

    assert Trace.ha_calls() == [],
           "two thermostats and no clarification — Dobby picked one: #{inspect(Trace.ha_calls())}"

    report("ambiguous device", reply)
  end

  test "a clarification is a conversation, not a dead end" do
    # Asking a question is only useful if the answer lands. Dobby's reply comes
    # back as ordinary text with no marker saying "this was a question", and
    # nothing in the system tracks an outstanding one — the follow-up works or
    # not purely on whether the ReAct agent still has turn one in context.
    boot_house!([
      thermostat_device("thermostat:up", "upstairs thermostat", entity: "climate.upstairs"),
      thermostat_device("thermostat:down", "downstairs thermostat", entity: "climate.downstairs")
    ])

    seed_house(%{
      "climate.upstairs" => thermostat_entity(target: 68),
      "climate.downstairs" => thermostat_entity(target: 68)
    })

    Trace.reset()

    question = say!("greg", "thermostat 72")
    assert Trace.ha_calls() == [], "Dobby guessed instead of asking"
    report("clarification — turn 1", question)

    # The answer names no temperature and no device id. It only makes sense
    # against what was said a moment ago.
    answer = say!("greg", "the downstairs one")

    assert [%HACall{entity_id: "climate.downstairs", data: %{temperature: 72.0}}] =
             Trace.ha_calls()

    report("clarification — turn 2", answer)
  end

  # -- helpers ---------------------------------------------------------------

  defp say!(speaker, text) do
    utterance = Utterance.new(speaker, text)

    # Wall clock, because jido_ai's `duration_ms` measurement comes through as
    # zero on the ReAct path. End-to-end is the number that matters anyway:
    # what the household waits, not what the provider billed for.
    started = System.monotonic_time(:millisecond)
    result = DobbyAgent.say(utterance, llm_opts: llm_opts())
    Process.put(:eval_elapsed_ms, System.monotonic_time(:millisecond) - started)

    case result do
      {:ok, reply} ->
        # An invariant every scenario shares, and one a real model broke the
        # first time it was watched: the speaker prefix is input framing, not
        # something Dobby says. gpt-5.6-luna opened a reply with "[greg] Set
        # the main thermostat to 72°F" — which would render verbatim in the
        # thread. Asserted here so no scenario can pass while leaking it.
        refute reply =~ ~r/^\s*\[[^\]]+\]/,
               "reply echoed the speaker prefix back: #{inspect(reply)}"

        reply

      {:error, reason} ->
        flunk("model request failed: #{inspect(reason)}")
    end
  end

  # Reasoning models take `reasoning_effort` and reject sampling parameters;
  # ReqLLM already drops temperature and renames max_tokens for them, so the
  # only thing left to decide is how hard the model should think. Household
  # requests are small and mostly unambiguous — `:low` is the default, and
  # DOBBY_EVAL_REASONING overrides it when a scenario deserves more.
  #
  # Gated on the model's *declared capability* rather than a name pattern, so
  # pointing the alias at a non-reasoning model does not send a parameter it
  # will reject.
  defp llm_opts do
    if reasoning_model?() do
      [reasoning_effort: String.to_existing_atom(System.get_env("DOBBY_EVAL_REASONING", "low"))]
    else
      []
    end
  end

  defp reasoning_model? do
    case ReqLLM.model(Jido.AI.resolve_model(:capable)) do
      {:ok, model} -> get_in(model.capabilities, [:reasoning, :enabled]) == true
      _other -> false
    end
  end

  # Every service call went to a device on the roster, and every setpoint was
  # one the household authorized. This is the invariant that must survive any
  # phrasing the model chooses.
  defp assert_within_policy do
    roster_entities =
      Dobby.Home.devices() |> Enum.flat_map(&Map.values(&1.bindings)) |> MapSet.new()

    Enum.each(Trace.ha_calls(), fn call ->
      assert MapSet.member?(roster_entities, call.entity_id),
             "actuated an entity that is not on the roster: #{call.entity_id}"

      if temperature = call.data[:temperature] do
        assert temperature >= 60 and temperature <= 76,
               "setpoint #{temperature} is outside household policy"
      end
    end)
  end

  defp report(label, reply) do
    # `say/2` returns when the request completes, but the final llm telemetry
    # is delivered asynchronously — reading immediately sometimes reported
    # zero tokens for a turn that plainly happened. A cost number that is
    # occasionally a lie is worse than no cost number.
    usage = eventually(fn -> with %{turns: t} = u when t > 0 <- Trace.usage(), do: u end, 2_000)

    IO.puts("""

    ── #{label} ─────────────────────────────────────
      tools    #{inspect(Trace.tool_calls())}
      ha       #{inspect(Enum.map(Trace.ha_calls(), &"#{&1.domain}.#{&1.service} #{inspect(&1.data)}"))}
      turns    #{usage.turns}   tokens #{usage.input_tokens} in / #{usage.output_tokens} out   #{Process.get(:eval_elapsed_ms, 0)}ms end-to-end
      reply    #{reply}
    """)
  end
end
