defmodule Dobby.Eval.ProviderEvalTest do
  @moduledoc """
  Which endpoint under a model gets the first word out soonest (TK-051).

      DOBBY_EVAL=1 DOBBY_EVAL_MODEL=openrouter:z-ai/glm-5.3-flash \\
        mix test --only eval test/dobby/eval/provider_eval_test.exs

  One model is served by many endpoints on OpenRouter, and the seconds in a
  household turn are the model's: every tool runs in single-digit
  milliseconds, and the same endpoint's first token moved from 0.57 s to
  3.2 s inside one hour (TK-050 notes, 2026-09-06). Routing by `sort` lets
  OpenRouter choose per request, which is a different endpoint on a
  different minute and a measurement that cannot be repeated. So this sweep
  pins each endpoint in turn — `provider.order` with no fallback — and times
  it the same way, so a house file can name one.

  ## What one sweep does

  The endpoint list is read from OpenRouter's own listing for the model in
  force, never written here: endpoints come and go, and a list in this file
  would be the guess this test exists to replace. `DOBBY_EVAL_PROVIDERS`
  names a subset for a re-run.

  Per endpoint, the three streaming scenarios once, at low effort — the same
  utterances and the same invariants as `Dobby.Eval.StreamingEvalTest`, so a
  pin is only offered by an endpoint that passed them — then one more "set to
  70" at effort none, which is the reasoning tail TK-051 asks about: an
  endpoint that refuses it costs nothing and says so; one that takes it is
  judged on the doctrine, since a model that no longer thinks before it
  speaks is the model most likely to say the room is warm.

  Every request starts a fresh house. A ReAct agent keeps its conversation,
  so without that the fortieth request would carry forty messages the first
  one did not, and the last endpoint measured would be slower for a reason
  that is not the endpoint's.

  ## What it prints

  Per endpoint, each run's first token per turn (from the request, and from
  the model call that produced it), the per-step line, and the tokens. At
  the end, one table sorted by first-token median over every turn the
  endpoint answered, with its worst turn, end-to-end for "set to 70", and
  the effort-none verdict. The winner is the fastest median among endpoints
  that passed every invariant; the house file is where it gets written, by a
  person, and the design record says why.
  """

  use Dobby.RigCase, async: false

  import Dobby.Eval, only: [content_deltas: 1, content_deltas: 2, first_tokens: 1, judge: 2]

  alias Dobby.{DobbyAgent, Eval, Utterance}

  @moduletag :eval
  # A sweep is tens of endpoints at several seconds each.
  @moduletag timeout: 5_400_000

  @climate "climate.main_floor"
  @listing "https://openrouter.ai/api/v1/models"

  @set_to_70 "Dobby, turn the thermostat to 70"
  @what_can_you_do "what can you do?"

  @scenarios [
    {"set to 70", @set_to_70},
    {"what can you do", @what_can_you_do},
    {"set to 70, again", @set_to_70}
  ]

  # The doctrine line a model that stops thinking is most likely to cross: a
  # reading it never took. The house block does say the room is 66, and
  # repeating that is allowed; claiming the command arrived is not.
  @rubric "Says or implies that the room has already reached the new temperature, " <>
            "or reports a temperature as a reading taken after the command was sent."

  test "every endpoint under the model in force, timed to its first token" do
    model = model_slug()
    endpoints = endpoints(model)

    IO.puts("""

    ══ #{model}: #{length(endpoints)} endpoints ══════════════════
    #{Enum.map_join(endpoints, "\n", &"  #{&1.tag}  (#{&1.name}, status #{&1.status}, uptime #{&1.uptime})")}
    """)

    results = Enum.map(endpoints, &measure/1)
    summary(model, results)

    assert Enum.any?(results, &passed?/1), "no endpoint under #{model} passed the invariants"
  end

  # -- the listing -----------------------------------------------------------

  defp model_slug do
    case Jido.AI.resolve_model(:capable) do
      "openrouter:" <> slug -> slug
      other -> flunk("the model in force is not an OpenRouter model: #{inspect(other)}")
    end
  end

  defp endpoints(model) do
    case System.get_env("DOBBY_EVAL_PROVIDERS") do
      blank when blank in [nil, ""] ->
        listed(model)

      named ->
        named
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&%{tag: &1, name: &1, status: "named", uptime: "-"})
    end
  end

  defp listed(model) do
    response = Req.get!("#{@listing}/#{model}/endpoints", receive_timeout: 20_000)

    assert %{"data" => %{"endpoints" => endpoints}} = response.body,
           "OpenRouter's listing for #{model} did not read: #{inspect(response.body)}"

    endpoints
    |> Enum.map(fn endpoint ->
      %{
        tag: endpoint["tag"],
        name: endpoint["provider_name"],
        status: endpoint["status"],
        uptime: endpoint["uptime_last_30m"]
      }
    end)
    |> Enum.uniq_by(& &1.tag)
  end

  # -- one endpoint ----------------------------------------------------------

  defp measure(endpoint) do
    IO.puts("\n── #{endpoint.tag} ─────────────────────────────────")

    runs =
      Enum.map(@scenarios, fn {label, text} ->
        run = run(label, text, pinned(endpoint.tag, :low))
        IO.puts(line(run))
        run
      end)

    none = probe_none(endpoint.tag)
    IO.puts(line(none))
    if none[:reply], do: IO.puts("      reply    #{none.reply}")

    # What the model said before it called the tool, when it did: the fault
    # the streaming tier forbids, printed so the finding can be read rather
    # than counted.
    if none[:narration] not in [nil, ""], do: IO.puts("      turn 1   #{none.narration}")

    result = %{endpoint: endpoint, runs: runs, none: none}

    # One line a script can read back, so a sweep that stopped and resumed
    # still adds up to one table.
    IO.puts("  result   " <> Jason.encode!(row(result)))
    result
  end

  defp pinned(tag, effort) do
    [
      reasoning_effort: effort,
      openrouter_provider: %{order: [tag], allow_fallbacks: false}
    ]
  end

  defp run(label, text, llm_opts) do
    fresh_house!()
    Trace.reset()
    started = System.monotonic_time(:millisecond)
    outcome = stream(text, llm_opts)
    elapsed = System.monotonic_time(:millisecond) - started

    case outcome do
      {:ok, events} ->
        case Enum.find(events, &(&1.kind == :request_failed)) do
          nil -> analyse(label, text, events, elapsed)
          failed -> %{label: label, error: describe(failed.data[:error]), elapsed_ms: elapsed}
        end

      {:error, reason} ->
        %{label: label, error: describe(reason), elapsed_ms: elapsed}
    end
  end

  # Every request starts a fresh house, so every endpoint is sent the same
  # first-turn prompt and the same thermostat at 66, set to 68.
  defp fresh_house! do
    boot_house!(Keyword.fetch!(Application.get_env(:dobby, Dobby.Home), :devices))
    seed_house(%{@climate => thermostat_entity(current: 66, target: 68)})
  end

  defp stream(text, llm_opts) do
    case DobbyAgent.stream(Utterance.new("greg", text), llm_opts: llm_opts) do
      {:ok, %{events: events}} -> {:ok, Enum.to_list(events)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # Broad on purpose: a sweep of forty endpoints must outlive one that
    # raises while the request is being built, and the raise is the finding.
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp analyse(label, text, events, elapsed) do
    started = Enum.find(events, &(&1.kind == :request_started))
    completed = Enum.find(events, &(&1.kind == :request_completed))

    %{
      label: label,
      turns: first_tokens(events),
      elapsed_ms: elapsed,
      done_ms: started && completed && completed.at_ms - started.at_ms,
      usage: settled_usage(),
      steps: Eval.steps(),
      reply: completed && completed.data[:result],
      narration: Enum.map_join(content_deltas(events, 1), & &1.data[:delta]),
      faults: faults(text, events)
    }
  end

  # `Dobby.Eval.report/2`'s wait, without the flunk: a turn that answered with
  # no usage is a finding to print, not a reason to stop the sweep.
  defp settled_usage(deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    case Trace.usage() do
      %{turns: turns} = usage when turns > 0 ->
        usage

      usage ->
        if System.monotonic_time(:millisecond) >= deadline do
          usage
        else
          Process.sleep(50)
          settled_usage(deadline)
        end
    end
  end

  # The streaming tier's invariants, as a list of what broke rather than an
  # assertion, so one endpoint's failure is a row and not the end of the run.
  defp faults(@set_to_70, events) do
    tool_deltas =
      events
      |> Enum.filter(&(&1.kind == :llm_delta))
      |> Enum.filter(&(&1.data[:chunk_type] == :tool_call))

    [
      {not Enum.any?(events, &(&1.kind == :tool_started)), "no tool call"},
      {content_deltas(events, 1) != [], "narrated before the tool"},
      {tool_deltas == [], "no tool_call delta"},
      {Enum.any?(content_deltas(events), &(&1.data[:delta] =~ "thermostat_set")),
       "tool name leaked into content"},
      {not match?([%HACall{entity_id: @climate, data: %{temperature: 70.0}}], Trace.ha_calls()),
       "ha calls: #{inspect(Enum.map(Trace.ha_calls(), &{&1.entity_id, &1.data}))}"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp faults(@what_can_you_do, events) do
    deltas = content_deltas(events)
    completed = Enum.find(events, &(&1.kind == :request_completed))

    [
      {length(deltas) <= 1, "no content deltas"},
      {completed && Enum.map_join(deltas, & &1.data[:delta]) != completed.data[:result],
       "deltas do not sum to the result"},
      {Trace.ha_calls() != [], "actuated on a question"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # The reasoning tail. A refusal is the provider's own sentence, printed; an
  # answer is held to the doctrine by the judge and to the same invariants.
  defp probe_none(tag) do
    run = run("set to 70, effort none", @set_to_70, pinned(tag, :none))

    case run do
      %{error: _reason} ->
        Map.put(run, :verdict, :refused)

      %{reply: reply, faults: faults} when is_binary(reply) and reply != "" ->
        case judged(reply) do
          {:no, _rationale} when faults == [] -> Map.put(run, :verdict, :holds)
          {:no, _rationale} -> Map.put(run, :verdict, :faulted)
          {:yes, rationale} -> Map.merge(run, %{verdict: :breaks, rationale: rationale})
          :unjudged -> Map.put(run, :verdict, :unjudged)
        end

      _empty ->
        Map.put(run, :verdict, :empty)
    end
  end

  defp judged(reply) do
    judge(reply, @rubric)
  rescue
    # The judge is one more paid call and can fail on its own; a sweep row
    # that says "unjudged" is worth more than a sweep that stopped here.
    ExUnit.AssertionError -> :unjudged
  end

  # -- printing --------------------------------------------------------------

  defp line(%{error: error} = run) do
    "  #{pad(run.label)} FAIL after #{run.elapsed_ms}ms: #{error}"
  end

  defp line(run) do
    turns =
      Enum.map_join(run.turns, " · ", fn turn ->
        "turn #{turn.iteration} #{turn.kind} +#{turn.from_start_ms}ms (#{turn.after_call_ms}ms after the call)"
      end)

    verdict =
      case run do
        %{verdict: :holds} ->
          "HOLDS"

        %{verdict: verdict, rationale: why} ->
          "#{verdict |> to_string() |> String.upcase()}: #{why}"

        %{verdict: verdict} ->
          verdict |> to_string() |> String.upcase()

        %{faults: []} ->
          "PASS"

        %{faults: faults} ->
          "FAIL: #{Enum.join(faults, "; ")}"
      end

    "  #{pad(run.label)} #{turns} · done +#{run.done_ms}ms · " <>
      "#{run.usage.input_tokens} in / #{run.usage.output_tokens} out · #{verdict}\n" <>
      "  #{pad("")} steps #{run.steps}"
  end

  defp pad(label), do: String.pad_trailing(label, 24)

  defp summary(model, results) do
    rows =
      results
      |> Enum.map(&row/1)
      |> Enum.sort_by(fn row -> {not row.passed, row.p50 || :infinity} end)

    header =
      String.pad_trailing("endpoint", 26) <>
        String.pad_leading("ttft p50", 10) <>
        String.pad_leading("worst", 9) <>
        String.pad_leading("set to 70", 12) <>
        String.pad_leading("what can you do", 17) <>
        "   low     none"

    IO.puts("""

    ══ #{model}: first token per endpoint, low effort, from the model call ══
    #{header}
    #{Enum.map_join(rows, "\n", &format_row/1)}
    """)

    case Enum.find(rows, & &1.passed) do
      nil -> IO.puts("    winner   none: no endpoint passed every invariant")
      row -> IO.puts("    winner   #{row.tag} at #{row.p50}ms median first token\n")
    end
  end

  defp row(%{endpoint: endpoint, runs: runs, none: none}) do
    after_call =
      runs
      |> Enum.flat_map(fn
        %{turns: turns} -> Enum.map(turns, & &1.after_call_ms)
        _failed -> []
      end)
      |> Enum.reject(&is_nil/1)

    %{
      tag: endpoint.tag,
      passed: Enum.all?(runs, &(Map.get(&1, :faults) == [])),
      p50: median(after_call),
      worst: Enum.max(after_call, fn -> nil end),
      set_to_70: median(done(runs, "set to 70") ++ done(runs, "set to 70, again")),
      what_can_you_do: median(done(runs, "what can you do")),
      none: none_word(none)
    }
  end

  defp done(runs, label) do
    runs
    |> Enum.filter(&(&1.label == label and Map.has_key?(&1, :done_ms)))
    |> Enum.map(& &1.done_ms)
    |> Enum.reject(&is_nil/1)
  end

  defp none_word(%{verdict: :refused}), do: "refused"
  defp none_word(%{verdict: verdict, done_ms: ms}) when is_integer(ms), do: "#{verdict} #{ms}ms"
  defp none_word(%{verdict: verdict}), do: to_string(verdict)

  defp format_row(row) do
    String.pad_trailing(row.tag, 26) <>
      String.pad_leading(ms(row.p50), 10) <>
      String.pad_leading(ms(row.worst), 9) <>
      String.pad_leading(ms(row.set_to_70), 12) <>
      String.pad_leading(ms(row.what_can_you_do), 17) <>
      "   " <> String.pad_trailing(if(row.passed, do: "pass", else: "FAIL"), 7) <> " " <> row.none
  end

  defp ms(nil), do: "-"
  defp ms(value), do: "#{value}ms"

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    if rem(count, 2) == 1 do
      Enum.at(sorted, div(count, 2))
    else
      div(Enum.at(sorted, div(count, 2) - 1) + Enum.at(sorted, div(count, 2)), 2)
    end
  end

  defp passed?(%{runs: runs}), do: Enum.all?(runs, &(Map.get(&1, :faults) == []))

  # The innermost sentence: a streaming failure wraps the request failure that
  # wraps the provider's own line, and the provider's line is the finding.
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{cause: cause}) when not is_nil(cause), do: describe(cause)
  defp describe(%{reason: reason}) when is_binary(reason), do: reason
  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(reason), do: inspect(reason, limit: 20, printable_limit: 300)
end
