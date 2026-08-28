defmodule Dobby.Eval.ModelSettingsEvalTest do
  @moduledoc """
  Whether what the house file says about the model reaches the provider.

      DOBBY_EVAL=1 mix test --only eval test/dobby/eval/model_settings_eval_test.exs

  `reasoning` and `routing` (`Dobby.HomeConfig.System.llm_opts/1`) travel as
  per-request options: the environment at boot, the writer on a save, and
  `Dobby.DobbyAgent` reading the environment on every request. The replay tier
  proves the first two. It cannot prove the third — jido_ai's llm telemetry
  carries the model and nothing else, and a scripted turn never builds a
  request body — so this is the one place the whole path is watched end to end.

  Watched through the production entry point, `DobbyAgent.say/1`, with no
  `llm_opts` passed: the eval helpers pass their own, which is exactly the path
  this file is not about.

  ## Free, on purpose

  A routing preference no provider can satisfy is refused before anything is
  generated, so a request that arrives carrying it costs nothing and fails in
  a way only the option's arrival explains. Model-agnostic too: every model on
  OpenRouter is served by *some* provider, and none by this one.
  """

  use Dobby.RigCase, async: false

  alias Dobby.{DobbyAgent, Utterance}

  @moduletag :eval
  @moduletag timeout: 60_000

  @climate "climate.main_floor"

  setup do
    seed_house(%{@climate => thermostat_entity(current: 66, target: 68)})
    Trace.reset()

    previous = Application.get_env(:dobby, :llm_opts)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dobby, :llm_opts, previous),
        else: Application.delete_env(:dobby, :llm_opts)
    end)

    :ok
  end

  test "what the house file says about the model reaches the provider, with nothing passed by the caller" do
    Application.put_env(:dobby, :llm_opts,
      openrouter_provider: %{order: ["not-a-real-provider"], allow_fallbacks: false}
    )

    assert {:error, reason} = DobbyAgent.say(Utterance.new("greg", "Dobby, what can you do?"))

    assert inspect(reason) =~ "No endpoints found",
           "expected OpenRouter to refuse the impossible routing, got: #{inspect(reason)}"

    # Refused at the provider, so nothing was generated and nothing was done.
    assert Trace.ha_calls() == []
  end

  test "and with the settings a house would actually write, the same path answers" do
    Application.put_env(:dobby, :llm_opts,
      reasoning_effort: :low,
      openrouter_provider: %{sort: "latency"}
    )

    # Timed the way `Dobby.Eval.say!/2` times its own requests, since this one
    # deliberately does not go through it, so `report/2` has a number to print.
    started = System.monotonic_time(:millisecond)

    assert {:ok, reply} =
             DobbyAgent.say(Utterance.new("greg", "Dobby, turn the thermostat to 70"))

    Process.put(:eval_elapsed_ms, System.monotonic_time(:millisecond) - started)

    assert [%HACall{entity_id: @climate, data: %{temperature: 70.0}}] = Trace.ha_calls()

    Dobby.Eval.report("house settings, production path", reply)
  end
end
