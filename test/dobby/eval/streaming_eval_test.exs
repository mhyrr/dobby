defmodule Dobby.Eval.StreamingEvalTest do
  @moduledoc """
  What a real request actually emits on the wire (surface design §14).

      DOBBY_EVAL=1 mix test --only eval

  The replay tier cannot answer this. A scripted turn goes through
  `consume_generate` (`react/runner.ex:490`) and never enters the streaming
  path, so it emits no `:llm_delta` at all — every event the thread renders
  from deltas is invisible to `mix test`. This is the one place the delta
  stream is watched against a real model.

  ## What it settled

  **Turn 1 does not narrate.** On an actuating request, iteration 1 emitted
  zero content deltas: the model called the tool and said nothing first. The
  design's proposal to fold pre-tool narration into a step label was written
  against a case that does not happen, and was dropped rather than built.

  **A tool call streams as a delta too.** Iteration 1 emitted exactly one
  `:llm_delta` with `chunk_type: :tool_call` whose payload is the tool's
  *name*. A thread rendering every delta would have put
  `thermostat_set_temperature` in the middle of Dobby's reply.

  **Deltas are words, not characters.** Twenty-five for a long answer, nine
  for a short one, over a second or two. Republishing each one to LiveView
  needs no batching.

  The assertions below are the invariants the thread depends on; the rest is
  printed for a person to read rather than pinned.
  """

  use Dobby.RigCase, async: false

  alias Dobby.{DobbyAgent, Home, Utterance}

  @moduletag :eval
  @moduletag timeout: 180_000

  @climate "climate.main_floor"

  setup do
    seed_house(%{@climate => thermostat_entity(current: 66, target: 68)})
    Trace.reset()
    :ok
  end

  test "an actuating request calls the tool without narrating first" do
    events = stream!("greg", "Dobby, turn the thermostat to 70")
    report(events)

    assert Enum.any?(events, &(&1.kind == :tool_started))

    # The finding the fold-into-step rule was proposed for, and against.
    assert content_deltas(events, 1) == []
  end

  test "the reply a person watches arrive is the reply that gets stored" do
    events = stream!("greg", "what can you do?")
    report(events)

    deltas = content_deltas(events)
    assert length(deltas) > 1, "no content deltas: streaming is not reaching the thread"

    completed = Enum.find(events, &(&1.kind == :request_completed))

    # The invariant the surface stands on. If the deltas ever stop summing to
    # the result, a person watches one sentence appear and a different one
    # gets written down.
    assert Enum.map_join(deltas, & &1.data[:delta]) == completed.data[:result]
  end

  test "a tool call streams as a delta, and it is not reply text" do
    events = stream!("greg", "Dobby, turn the thermostat to 70")

    tool_deltas =
      events
      |> Enum.filter(&(&1.kind == :llm_delta))
      |> Enum.filter(&(&1.data[:chunk_type] == :tool_call))

    assert tool_deltas != [], "expected the tool call to stream as a delta"
    assert Enum.any?(tool_deltas, &(&1.data[:delta] =~ "thermostat"))

    # And none of it reaches the thread, because the thread reads
    # `chunk_type: :content` only.
    refute Enum.any?(content_deltas(events), &(&1.data[:delta] =~ "thermostat_set"))
  end

  defp stream!(speaker, text) do
    utterance = Utterance.new(speaker, text)
    pid = Dobby.Jido.whereis(DobbyAgent.id())

    {:ok, %{events: events}} =
      DobbyAgent.ask_stream(pid, Utterance.to_message(utterance),
        tools: Home.tools(),
        tool_context: %{speaker: speaker},
        llm_opts: Dobby.Eval.llm_opts()
      )

    Enum.to_list(events)
  end

  defp content_deltas(events, iteration \\ nil) do
    events
    |> Enum.filter(&(&1.kind == :llm_delta and &1.data[:chunk_type] == :content))
    |> Enum.filter(&(is_nil(iteration) or &1.iteration == iteration))
    |> Enum.sort_by(& &1.seq)
  end

  defp report(events) do
    deltas = content_deltas(events)
    seqs = Enum.map(events, & &1.seq)

    # Arrival order is not emission order. A swap has been seen here, which is
    # why the thread keys deltas by `seq` rather than appending them.
    inversions =
      seqs
      |> Enum.zip(tl(seqs) ++ [nil])
      |> Enum.count(fn {a, b} -> is_integer(b) and b < a end)

    IO.puts("""

    ── stream ───────────────────────────────────────
      events   #{length(events)}   content deltas #{length(deltas)}
      kinds    #{inspect(events |> Enum.map(& &1.kind) |> Enum.frequencies())}
      arrival-order inversions   #{inversions}
      reply    #{Enum.map_join(deltas, & &1.data[:delta])}
    """)
  end
end
