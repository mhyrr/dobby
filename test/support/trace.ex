defmodule Dobby.Trace do
  @moduledoc """
  What a scenario made happen, gathered from telemetry.

  Telemetry is the only seam that spans every agent without threading a
  collector through production code: Jido emits an event for every signal into
  every agent, Jido AI emits one per LLM call and per tool call, and Dobby's
  `HACall` executor emits one per service call.

  ## What this can and cannot tell you

  It answers **what happened and how much**, per source, in order:

      Trace.ha_calls()    # service calls that actually executed
      Trace.tool_calls()  # tools the model invoked, by name
      Trace.llm_calls()   # model turns — `[]` is often the assertion
      Trace.signals()     # {agent_id, signal_type} in Dobby's vocabulary

  It does **not** give a reliable interleaving *between* those sources.
  Jido's signal events and Dobby's `HACall` event carry a `system_time`
  measurement stamped by the emitter; `jido.ai.llm.start` and
  `jido.ai.tool.start` carry none, so their position can only be inferred from
  when the handler ran, which is not the same thing. A merged ordering built
  from that mix reads plausibly and is wrong — measured here, the `HACall`
  sorted ahead of the LLM turn that caused it.

  So: assert cross-source *ordering* with `assert_receive` on the events
  themselves, which is a real happens-before. Use this module for the pattern
  and the counts, which is what the replay tier is actually pinning.

  The interesting assertion is often a zero: a schedule firing must contain no
  model call, and a clarification must contain no `HACall`.
  """

  use GenServer

  @events [
    [:jido, :agent_server, :signal, :start],
    [:jido, :ai, :llm, :start],
    [:jido, :ai, :llm, :complete],
    [:jido, :ai, :tool, :start],
    [:dobby, :ha, :call]
  ]

  @dobby_signal_prefixes ["dobby.", "ha.", "thermostat."]

  # -- client ----------------------------------------------------------------

  @doc """
  Starts collecting. Detaches when the calling test exits.
  """
  @spec start!() :: pid()
  def start! do
    {:ok, pid} = GenServer.start_link(__MODULE__, [], name: __MODULE__)
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, pid)
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)

    pid
  end

  @doc """
  Every recorded entry, in capture order.
  """
  @spec events() :: [map()]
  def events, do: GenServer.call(__MODULE__, :events)

  @doc """
  Drops everything recorded so far.

  Call it after arranging the house so a scenario's trace starts at the
  utterance rather than at setup.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Model turns. `[]` is the assertion that nothing reached an LLM.
  """
  @spec llm_calls() :: [map()]
  def llm_calls, do: of_kind(:llm_call)

  @doc """
  Tool names the model invoked, in order.

  Names only: Jido AI's tool telemetry does not carry arguments — assert those
  against the tool's own result, or against `ha_calls/0` downstream of it.
  """
  @spec tool_calls() :: [String.t()]
  def tool_calls, do: of_kind(:tool_call) |> Enum.map(& &1.tool_name)

  @doc """
  Home Assistant service calls that actually executed, in order.
  """
  @spec ha_calls() :: [Dobby.Directive.HACall.t()]
  def ha_calls, do: of_kind(:ha_call) |> Enum.map(& &1.call)

  @doc """
  Signals delivered to agents, as `{agent_id, signal_type}`.

  Filtered to Dobby's own vocabulary: the raw stream is mostly Jido AI's
  internal request chatter, and pinning that would pin implementation detail
  rather than behavior.
  """
  @spec signals() :: [{String.t(), String.t()}]
  def signals do
    of_kind(:signal)
    |> Enum.filter(&dobby_signal?/1)
    |> Enum.map(&{&1.agent_id, &1.signal_type})
  end

  @doc """
  Token and latency totals for the scenario.

  Recorded from day one because the eval tier's whole cost model is "how much
  does one household request cost", and that is not a number to start guessing
  about after the fact.
  """
  @spec usage() :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          duration_ms: number(),
          turns: non_neg_integer()
        }
  def usage do
    done = of_kind(:llm_done)

    %{
      input_tokens: Enum.sum(Enum.map(done, & &1.input_tokens)),
      output_tokens: Enum.sum(Enum.map(done, & &1.output_tokens)),
      duration_ms: Enum.sum(Enum.map(done, & &1.duration_ms)),
      turns: length(done)
    }
  end

  @doc """
  How many of each kind — the cheapest form of "did the shape change".
  """
  @spec counts() :: %{llm: non_neg_integer(), tool: non_neg_integer(), ha: non_neg_integer()}
  def counts do
    %{llm: length(llm_calls()), tool: length(tool_calls()), ha: length(ha_calls())}
  end

  defp of_kind(kind), do: Enum.filter(events(), &(&1.kind == kind))

  defp dobby_signal?(%{signal_type: type}),
    do: Enum.any?(@dobby_signal_prefixes, &String.starts_with?(type, &1))

  # -- telemetry -------------------------------------------------------------

  @doc false
  def handle_event(event, measurements, metadata, pid) do
    GenServer.cast(pid, {:record, entry(event, measurements, metadata)})
  end

  defp entry([:jido, :agent_server, :signal, :start], _measurements, metadata) do
    %{kind: :signal, agent_id: metadata[:agent_id], signal_type: metadata[:signal_type]}
  end

  defp entry([:jido, :ai, :llm, :start], _measurements, metadata) do
    %{kind: :llm_call, model: metadata[:model], agent_id: metadata[:agent_id]}
  end

  defp entry([:jido, :ai, :tool, :start], _measurements, metadata) do
    %{kind: :tool_call, tool_name: metadata[:tool_name], agent_id: metadata[:agent_id]}
  end

  defp entry([:jido, :ai, :llm, :complete], measurements, metadata) do
    %{
      kind: :llm_done,
      model: metadata[:model],
      input_tokens: measurements[:input_tokens] || 0,
      output_tokens: measurements[:output_tokens] || 0,
      duration_ms: measurements[:duration_ms] || 0
    }
  end

  defp entry([:dobby, :ha, :call], _measurements, metadata) do
    %{kind: :ha_call, call: metadata.call, result: metadata.result}
  end

  # -- server ----------------------------------------------------------------

  @impl GenServer
  def init(_opts), do: {:ok, []}

  @impl GenServer
  def handle_cast({:record, entry}, entries), do: {:noreply, [entry | entries]}

  @impl GenServer
  def handle_call(:events, _from, entries), do: {:reply, Enum.reverse(entries), entries}
  def handle_call(:reset, _from, _entries), do: {:reply, :ok, []}
end
