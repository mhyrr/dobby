defmodule Dobby.Conversation.Turn do
  @moduledoc """
  One request, from what somebody said to what Dobby answered (design §10.7).

  ## Why this is a task and not a LiveView

  `Jido.AI.Agent.ask_stream/3` sets `stream_to: {:pid, self()}` — the **calling**
  process is the event sink — and the enumerable it returns blocks in `receive`
  until the request terminates. A LiveView that called it would stop handling
  messages for the length of the request, so the task per request is forced by
  the library rather than chosen for tidiness.

  The task is also the only writer. It persists the utterance, republishes
  every runtime event to `dobby:thread`, persists the reply, and records the
  activity. Surfaces subscribe and render; they never write the thread. That
  is what makes two people watching the same request see the same document.

  ## What the events mean here

      :request_started    Dobby is working
      :tool_started       a step opens, in device language (`Dobby.Tools`)
      :tool_completed     the step resolves — or is HELD, if the device declined
      :llm_delta          reply text, but only `chunk_type: :content`
      :request_completed  the reply, the usage, the end

  **Only `:content` deltas are text.** A tool call streams too, as a delta with
  `chunk_type: :tool_call` whose payload is the tool's *name* — measured in the
  eval tier, where an actuating turn emitted exactly one of them. Rendering
  every delta would put `thermostat_set_temperature` in the middle of Dobby's
  reply.

  ## Failure is a line in the thread, not a silence

  A request that fails, is cancelled, or comes back empty writes a system line
  saying so. A household surface that shows an utterance and then nothing at
  all is the worst version of this: the person cannot tell whether Dobby is
  slow, broken, or ignoring them.
  """

  require Logger

  alias Dobby.Activity
  alias Dobby.Conversation
  alias Dobby.Conversation.Speaker
  alias Dobby.DobbyAgent
  alias Dobby.Interventions
  alias Dobby.ThreadEvents
  alias Dobby.Utterance
  alias Jido.AI.Runtime.Event

  @doc """
  Says something to Dobby.

  Hands the utterance to `Dobby.Conversation.Turn.Queue`, which writes it into
  the thread straight away and asks when Dobby is free. Returns immediately;
  everything the caller needs arrives on `dobby:thread`, including the caller's
  own utterance. That is deliberate — one path writes the thread, so a surface
  cannot end up rendering an optimistic copy of a message that never persisted.
  """
  @spec say(Utterance.t(), Speaker.t(), keyword()) :: :ok
  def say(%Utterance{} = utterance, %Speaker{} = speaker, opts \\ []) do
    __MODULE__.Queue.say(utterance, speaker, opts)
  end

  @doc """
  Writes an utterance into the thread and returns its request id.

  Separate from asking, because the two happen at different times once there is
  a queue: what somebody said belongs in the thread the moment they said it,
  and the answer comes when Dobby gets to it. A person whose words sat
  invisible until the agent freed up would reasonably conclude the house had
  stopped listening.
  """
  @spec record(Utterance.t(), Speaker.t()) :: {:ok, String.t()} | :error
  def record(%Utterance{} = utterance, %Speaker{} = speaker) do
    request_id = Jido.Util.generate_id()

    case Conversation.append_utterance(utterance, speaker, request_id: request_id) do
      {:ok, message} ->
        ThreadEvents.said(%{message | speaker: speaker})
        {:ok, request_id}

      {:error, changeset} ->
        Logger.error("could not record an utterance: #{inspect(changeset.errors)}")
        :error
    end
  end

  @doc """
  Runs a turn in the calling process, queue and all skipped.

  `say/3` is the production entry point. This is exposed because the calling
  process is the event sink: a test that wants a turn to have finished before
  it asserts has to be able to run one synchronously.
  """
  @spec run(Utterance.t(), Speaker.t(), keyword()) :: :ok
  def run(%Utterance{} = utterance, %Speaker{} = speaker, opts \\ []) do
    case record(utterance, speaker) do
      {:ok, request_id} -> answer(utterance, speaker, request_id, opts)
      :error -> :ok
    end
  end

  @doc """
  Asks Dobby, for an utterance already in the thread.

  This is what the queue runs, one at a time. It is also where the rescue is:
  the process running it is nobody's supervisor and nobody's caller, so without
  it a crash anywhere below is a person watching their own message sit there
  forever with no reply and no explanation.
  """
  @spec answer(Utterance.t(), Speaker.t(), String.t(), keyword()) :: :ok
  def answer(%Utterance{} = utterance, %Speaker{} = speaker, request_id, opts \\ []) do
    ask(utterance, speaker, request_id, opts)
  rescue
    error ->
      Logger.error("turn crashed: #{Exception.format(:error, error, __STACKTRACE__)}")
      fail(request_id, "something went wrong answering that")
  end

  defp ask(utterance, speaker, request_id, opts) do
    opts = Keyword.put(opts, :request_id, request_id)

    case DobbyAgent.stream(utterance, opts) do
      {:ok, %{events: events}} ->
        ThreadEvents.turn_started(request_id)

        events
        |> Enum.reduce(new_turn(request_id, speaker), &handle/2)
        |> finish()

      {:error, :dobby_not_running} ->
        fail(request_id, "Dobby isn't running")

      {:error, reason} ->
        fail(request_id, "Dobby couldn't answer that", describe(reason))
    end
  end

  defp new_turn(request_id, speaker) do
    %{
      request_id: request_id,
      speaker: speaker.name,
      started_at: System.monotonic_time(:millisecond),
      steps: %{},
      arguments: %{},
      order: [],
      text: %{},
      result: nil,
      usage: %{},
      error: nil
    }
  end

  # -- events ----------------------------------------------------------------

  defp handle(
         %Event{kind: :llm_delta, seq: seq, data: %{chunk_type: :content, delta: text}},
         turn
       )
       when is_binary(text) do
    ThreadEvents.delta(turn.request_id, seq, text)
    %{turn | text: Map.put(turn.text, seq, text)}
  end

  defp handle(%Event{kind: :tool_started, data: data}, turn) do
    id = data[:tool_call_id] || data[:tool_name]
    arguments = data[:arguments] || %{}

    step = %{
      id: id,
      label: Dobby.Tools.label(data[:tool_name] || "", arguments),
      state: :running,
      detail: nil
    }

    ThreadEvents.step(turn.request_id, step)

    %{
      turn
      | steps: Map.put(turn.steps, id, step),
        order: turn.order ++ [id],
        # `:tool_completed` carries the result and not the arguments, so what
        # the call was *for* has to be kept from the start of it. Without this
        # the activity log records a tool call against no device, which is the
        # one column `TK-004` reads by.
        arguments: Map.put(turn.arguments, id, arguments)
    }
  end

  defp handle(%Event{kind: :tool_completed, data: data}, turn) do
    id = data[:tool_call_id] || data[:tool_name]
    {state, detail} = outcome(data[:result])

    step =
      turn.steps
      |> Map.get(id, %{id: id, label: Dobby.Tools.label(data[:tool_name] || "", %{})})
      |> Map.merge(%{state: state, detail: detail})

    ThreadEvents.step(turn.request_id, step)
    record_tool_call(turn, data, Map.get(turn.arguments, id, %{}), state)
    record_intervention(turn, data)

    %{turn | steps: Map.put(turn.steps, id, step)}
  end

  defp handle(%Event{kind: :request_completed, data: data}, turn) do
    %{turn | result: data[:result], usage: data[:usage] || %{}}
  end

  # The raw term, not a rendered string: what went wrong decides which sentence
  # the thread gets, and that decision belongs at the end of the turn.
  defp handle(%Event{kind: :request_failed, data: data}, turn) do
    %{turn | error: data[:error] || :unknown}
  end

  defp handle(%Event{kind: :request_cancelled, data: data}, turn) do
    %{turn | error: {:cancelled, data[:reason]}}
  end

  defp handle(%Event{}, turn), do: turn

  # A device that declined is not a failure of Dobby's, and the board says so
  # with a different word. `accepted: false` is the write-acknowledgment
  # protocol's own answer (§6.2) rather than something inferred here.
  defp outcome(result) do
    case normalize(result) do
      {:ok, %{accepted: false} = value} -> {:held, value[:reason]}
      {:error, reason} -> {:held, describe(reason)}
      _accepted -> {:done, nil}
    end
  end

  # A tool's result arrives as `Jido.Exec` returns it, which is
  # `{:ok, value, directives}` — not the `{:ok, value}` the action itself
  # wrote. Matching the two-element form alone reads every refusal as a
  # success, which is the one mistake this surface exists to prevent.
  defp normalize({tag, value, _directives}), do: {tag, value}
  defp normalize(result), do: result

  # -- the end of a turn -----------------------------------------------------

  defp finish(%{error: error} = turn) when not is_nil(error) do
    detail = describe(error)
    record_request(turn, %{ok: false, error: detail})
    fail(turn.request_id, sentence(error), detail)
    catch_up()
  end

  defp finish(turn) do
    case reply_text(turn) do
      "" ->
        record_request(turn, %{ok: false, error: "empty reply"})
        fail(turn.request_id, "Dobby had nothing to say")

      text ->
        record_request(turn, %{ok: true, reply: text})
        reply(turn, text)
    end

    catch_up()
  end

  # A turn that changed the house restarts it, once the turn is over.
  #
  # Restarting `Dobby.Home` stops `DobbyAgent` along with everything else, so a
  # confirmation that restarted the house from inside its own tool call would
  # write the file correctly and then lose the sentence saying so — the request
  # dies with the agent it is running on. So `Dobby.HomeConfig.Writer` writes,
  # validates and announces synchronously and holds the restart, and this is
  # where it is let go: after the reply is in the thread, by the process that
  # put it there. Every other turn finds nothing waiting and this costs a call.
  #
  # /admin and /house do not need it. A browser is not inside the request it is
  # changing; a conversation is.
  defp catch_up do
    case Dobby.HomeConfig.Writer.catch_up() do
      {:error, reason} ->
        Logger.error("the house would not take on a confirmed change: #{reason}")

      _idle_or_applied ->
        :ok
    end

    :ok
  catch
    # No writer means no house file to catch up with, which is every test that
    # does not boot the application.
    :exit, _reason -> :ok
  end

  # The result the runtime finished with, not the deltas — deltas are for
  # watching, and a scripted or non-streaming turn produces none at all.
  defp reply_text(%{result: result}) when is_binary(result), do: String.trim(result)

  defp reply_text(turn) do
    turn.text
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(&elem(&1, 1))
    |> String.trim()
  end

  defp reply(turn, text) do
    meta = %{
      "steps" => Enum.map(turn.order, &step_meta(Map.fetch!(turn.steps, &1))),
      "duration_ms" => elapsed(turn),
      "usage" => jsonable(turn.usage)
    }

    case Conversation.append_reply(text, request_id: turn.request_id, meta: meta) do
      {:ok, message} ->
        ThreadEvents.replied(message)
        :ok

      {:error, changeset} ->
        Logger.error("could not record a reply: #{inspect(changeset.errors)}")
        :ok
    end
  end

  defp step_meta(step) do
    %{
      "label" => step.label,
      "state" => to_string(step.state),
      "detail" => step[:detail]
    }
  end

  # One ReAct agent still takes one request at a time; `Turn.Queue` is what
  # stops a second utterance ever reaching it while the first is in flight.
  # This sentence should therefore be unreachable through `say/3` — it survives
  # for `run/3`, which deliberately skips the queue, and because a rejection
  # nobody can explain is worse than one with a sentence attached.
  defp sentence({:rejected, :busy, _status}), do: "Dobby is still working on the last one"
  defp sentence(_error), do: "Dobby couldn't answer that"

  # The line a person reads and the reason a maintainer needs are not the same
  # string. `{:http_streaming_failed, {:provider_build_failed, %ReqLLM.Error...`
  # is true and it is not a sentence, and painting it on a board in a kitchen
  # helps nobody standing in front of it. The sentence goes in the thread; the
  # raw reason goes in `meta` and the activity log, where somebody looking for
  # it will find it.
  defp fail(request_id, sentence, detail \\ nil) do
    meta =
      %{"kind" => "request_failed", "detail" => detail}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Conversation.append_system_line(sentence, meta, request_id: request_id) do
      {:ok, message} -> ThreadEvents.system_line(message)
      {:error, changeset} -> Logger.error("could not record a failure: #{inspect(changeset)}")
    end

    :ok
  end

  defp elapsed(turn), do: System.monotonic_time(:millisecond) - turn.started_at

  # -- the record ------------------------------------------------------------

  # A tool call that moved the house gets a line in the thread, attributed to
  # whoever asked (design §10.3). The reply already says what Dobby did
  # in his own words; the line is the record, and it is the same line a card
  # tap or a schedule writes — so scrolling back to yesterday shows one kind of
  # entry for "the thermostat went to 70", however it got there.
  #
  # Keyed on the write-acknowledgment protocol's own `accepted: true` rather
  # than on a list of tool names, so a reading tool cannot accidentally
  # announce an intervention and a future actuating one does not have to be
  # added here.
  defp record_intervention(turn, data) do
    case normalize(data[:result]) do
      {:ok, %{accepted: true, device: device, name: name} = value} ->
        Interventions.record(%{
          device: device,
          name: name,
          value: Interventions.reading(value),
          action: data[:tool_name],
          via: turn.speaker,
          request_id: turn.request_id
        })

      _not_an_actuation ->
        :ok
    end
  end

  defp record_tool_call(turn, data, arguments, state) do
    Activity.record(%{
      kind: "tool_call",
      actor: turn.speaker,
      device: arguments["device"] || arguments[:device],
      action: data[:tool_name],
      args: jsonable(arguments),
      result: %{"state" => to_string(state), "value" => jsonable(data[:result])},
      duration_ms: data[:duration_ms],
      request_id: turn.request_id
    })
  end

  defp record_request(turn, result) do
    Activity.record(%{
      kind: "request",
      actor: turn.speaker,
      action: "say",
      args: %{"steps" => length(turn.order)},
      result: jsonable(Map.put(result, :usage, turn.usage)),
      duration_ms: elapsed(turn),
      request_id: turn.request_id
    })
  end

  defp jsonable(value), do: Activity.jsonable(value)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{reason: reason}) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
