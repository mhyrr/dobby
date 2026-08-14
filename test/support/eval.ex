defmodule Dobby.Eval do
  @moduledoc """
  The eval tier's shared harness (design §12).

  Everything here is about making a real-model run *comparable* — same request
  shape, same invariants, same cost line printed underneath. It lives in one
  module because the invariants are the point: an assertion that only some
  eval files make is an assertion that stops being true without anyone noticing.
  """

  import ExUnit.Assertions

  alias Dobby.{DobbyAgent, Utterance}

  @doc """
  Says something to Dobby with a real model behind him, and returns the reply.

  Records wall-clock elapsed time for `report/2` — jido_ai's `duration_ms`
  comes through as zero on the ReAct path, and end-to-end is the number that
  matters anyway: what the household waits, not what the provider billed for.
  """
  @spec say!(String.t(), String.t()) :: String.t()
  def say!(speaker, text) do
    utterance = Utterance.new(speaker, text)

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

  @doc """
  Reasoning options for whichever model the run is pointed at.

  Reasoning models take `reasoning_effort` and reject sampling parameters;
  ReqLLM already drops temperature and renames max_tokens for them, so the only
  thing left to decide is how hard the model should think. Household requests
  are small and mostly unambiguous — `:low` is the default, and
  DOBBY_EVAL_REASONING overrides it when a scenario deserves more.

  Gated on the model's *declared capability* rather than a name pattern, so
  pointing the alias at a non-reasoning model does not send a parameter it will
  reject.
  """
  @spec llm_opts() :: keyword()
  def llm_opts do
    if reasoning_model?() do
      [reasoning_effort: String.to_existing_atom(System.get_env("DOBBY_EVAL_REASONING", "low"))]
    else
      []
    end
  end

  @doc """
  Whether the model this run resolves to declares reasoning support.
  """
  @spec reasoning_model?() :: boolean()
  def reasoning_model? do
    case ReqLLM.model(Jido.AI.resolve_model(:capable)) do
      {:ok, model} -> get_in(model.capabilities, [:reasoning, :enabled]) == true
      _other -> false
    end
  end

  @doc """
  Prints what one household request did and what it cost.

  Recorded from day one because "what does one household request cost" is not a
  number to start estimating later.
  """
  @spec report(String.t(), String.t()) :: :ok
  def report(label, reply) do
    # `say!/2` returns when the request completes, but the final llm telemetry
    # is delivered asynchronously — reading immediately sometimes reported zero
    # tokens for a turn that plainly happened. A cost number that is
    # occasionally a lie is worse than no cost number.
    usage =
      Dobby.RigCase.eventually(
        fn -> with %{turns: turns} = usage when turns > 0 <- Dobby.Trace.usage(), do: usage end,
        2_000
      )

    IO.puts("""

    ── #{label} ─────────────────────────────────────
      tools    #{inspect(Dobby.Trace.tool_calls())}
      ha       #{inspect(Enum.map(Dobby.Trace.ha_calls(), &"#{&1.domain}.#{&1.service} #{inspect(&1.data)}"))}
      turns    #{usage.turns}   tokens #{usage.input_tokens} in / #{usage.output_tokens} out   #{Process.get(:eval_elapsed_ms, 0)}ms end-to-end
      reply    #{reply}
    """)
  end

  @doc """
  Every service call went to a device on the roster, at a setpoint the
  household authorized.

  The invariant that must survive any phrasing a model chooses.
  """
  @spec assert_within_policy() :: :ok
  def assert_within_policy do
    roster_entities =
      Dobby.Home.devices() |> Enum.flat_map(&Map.values(&1.bindings)) |> MapSet.new()

    Enum.each(Dobby.Trace.ha_calls(), fn call ->
      assert MapSet.member?(roster_entities, call.entity_id),
             "actuated an entity that is not on the roster: #{call.entity_id}"

      if temperature = call.data[:temperature] do
        assert temperature >= 60 and temperature <= 76,
               "setpoint #{temperature} is outside household policy"
      end
    end)
  end
end
