defmodule Dobby.Conversation.Turn.Queue do
  @moduledoc """
  One person has the floor at a time (`TK-006`).

  A ReAct agent takes one request at a time. `Strategy.process_start/2` checks
  `busy?` and rejects a second one outright with `reason: :busy`, so before this
  existed a second utterance never reached the model at all — and two people
  saying something within a few seconds of each other is the ordinary case in a
  house at six in the evening. The thread said "Dobby is still working on the
  last one", which was true and threw the words away.

  Greg's call was hold and re-issue: **queue it.** Each utterance keeps its own
  turn, in order, and they run one at a time. The alternative was injecting the
  second utterance into the running request — jido has `:input_injected` — which
  would have meant Dobby answering two people in one reply. That changes what a
  turn *is*; this does not.

  ## What somebody sees while they wait

  Their words, immediately. Recording the utterance and asking about it are two
  steps here (`Turn.record/2` then `Turn.answer/4`) precisely so the first can
  happen at once and the second can wait its turn. A person whose message sat
  invisible until the agent freed up would reasonably conclude the house had
  stopped listening.

  Nothing else is shown. The realistic wait is one turn — two to four seconds —
  and a queue-position indicator is UI for a case nobody has watched happen yet.
  The seam is here if it turns out to matter.

  ## Why the queue also writes the thread

  Two people typing at the same instant both land here, and this process is
  single-file, so the order their words appear in the transcript is the order
  the answers come in. Persisting from the caller instead would let the thread
  and the queue disagree about who spoke first, which is exactly the kind of
  thing a shared household record must not do.

  ## Failure

  Every turn runs in a task under the application's supervisor and is
  monitored. A turn that crashes still frees the floor, because the next
  utterance in a house is not conditional on the last one having gone well.
  """

  use GenServer

  require Logger

  alias Dobby.Conversation.Speaker
  alias Dobby.Conversation.Turn
  alias Dobby.Utterance

  defstruct running: nil, waiting: :queue.new(), runner: nil

  # -- client ----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Puts an utterance in the thread now, and asks when Dobby is free.
  """
  @spec say(Utterance.t(), Speaker.t(), keyword()) :: :ok
  def say(%Utterance{} = utterance, %Speaker{} = speaker, opts \\ []) do
    GenServer.cast(__MODULE__, {:say, utterance, speaker, opts})
  end

  @doc """
  How many utterances are waiting for the floor.

  Zero whenever nothing is queued behind the running turn, which is the
  ordinary state of a house.
  """
  @spec waiting(GenServer.server()) :: non_neg_integer()
  def waiting(server \\ __MODULE__), do: GenServer.call(server, :waiting)

  @doc """
  Blocks until every utterance already said has been written down.

  A barrier, in the same family as `RigCase.drain_turns!`: a call queues behind
  everything already cast, so a reply means each of those utterances is in the
  thread. It says nothing about their answers — `drain_turns!` is what waits
  for those.
  """
  @spec recorded(GenServer.server()) :: :ok
  def recorded(server \\ __MODULE__) do
    _waiting = GenServer.call(server, :waiting, 5_000)
    :ok
  end

  # -- server ----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # The production runner is `Turn.answer/4`. It is injectable because the
    # queue's job is ordering and what it orders is a black box to it — a test
    # can hand it something that blocks on command, which is the only way to
    # observe ordering without racing a turn that finishes in microseconds.
    {:ok, %__MODULE__{runner: Keyword.get(opts, :runner, &Turn.answer/4)}}
  end

  @impl GenServer
  def handle_cast({:say, utterance, speaker, opts}, state) do
    case Turn.record(utterance, speaker) do
      {:ok, request_id} ->
        {:noreply, admit(state, {utterance, speaker, request_id, opts})}

      # The utterance could not be written down, so there is nothing to answer
      # and nothing anybody will see. `Turn.record/2` has already logged it.
      :error ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:waiting, _from, state), do: {:reply, :queue.len(state.waiting), state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref}} = state) do
    if reason != :normal do
      Logger.error("a turn died holding the floor: #{inspect(reason)}")
    end

    {:noreply, next(%{state | running: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- the floor -------------------------------------------------------------

  defp admit(%{running: nil} = state, turn), do: start(state, turn)

  defp admit(state, turn), do: %{state | waiting: :queue.in(turn, state.waiting)}

  defp next(state) do
    case :queue.out(state.waiting) do
      {{:value, turn}, waiting} -> start(%{state | waiting: waiting}, turn)
      {:empty, _waiting} -> state
    end
  end

  defp start(state, {utterance, speaker, request_id, opts} = turn) do
    runner = state.runner

    started =
      Task.Supervisor.start_child(Dobby.TaskSupervisor, fn ->
        runner.(utterance, speaker, request_id, opts)
      end)

    case started do
      {:ok, pid} ->
        %{state | running: %{ref: Process.monitor(pid), turn: turn}}

      # The floor stays clear rather than being held by a turn that never
      # started, which would wedge every utterance behind it for good.
      {:error, reason} ->
        Logger.error("could not start a turn: #{inspect(reason)}")
        next(%{state | running: nil})
    end
  end
end
