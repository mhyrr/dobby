defmodule Dobby.ThreadEvents do
  @moduledoc """
  The `dobby:thread` seam (design §11).

  One topic for the whole household thread, not one per request. The thread is
  a shared document: every connected surface wants every request's deltas, so
  per-request topics would mean every LiveView subscribing and unsubscribing on
  every utterance to receive exactly the same volume.

  Follows `Dobby.DeviceEvents` — the point of the module is that both sides
  agree on the payload in one place rather than in two that drift.

  ## The payloads

      {:said, %Message{}}                 somebody's utterance landed
      {:turn_started, request_id}         Dobby is working; open a pending row
      {:step, request_id, step}           a named step, in device language
      {:delta, request_id, seq, text}     reply text, as it arrives
      {:replied, %Message{}}              the reply landed; the pending row closes
      {:system_line, %Message{}}          the house changed, by any path

  A step is `%{id: String.t(), label: String.t(), state: :running | :done |
  :held, detail: String.t() | nil}`. `:held` is the device declining, which is
  a fact about the device and never a failure of Dobby's.

  ## On `seq`

  Deltas carry the runtime event's `seq` because **arrival order is not
  emission order**. `seq` is allocated in the runner
  (`react/runner.ex:1153`) and is monotonic within a run, but the events reach
  a subscriber through the agent server and PubSub, and a two-event swap has
  been observed in the rig. Rendering deltas in arrival order therefore
  scrambles words occasionally — rare, invisible in tests, and exactly the kind
  of thing that makes an honest board look broken. Consumers sort by `seq`.
  """

  alias Dobby.Conversation.Message

  @topic "dobby:thread"

  @doc """
  The PubSub topic carrying the thread.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the calling process to the thread.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Dobby.PubSub, @topic)

  @doc """
  Announces an utterance somebody made.
  """
  @spec said(Message.t()) :: :ok
  def said(%Message{} = message), do: broadcast({:said, message})

  @doc """
  Announces that Dobby has started working on a request.
  """
  @spec turn_started(String.t()) :: :ok
  def turn_started(request_id), do: broadcast({:turn_started, request_id})

  @doc """
  Announces a step of the work, in device language.
  """
  @spec step(String.t(), map()) :: :ok
  def step(request_id, step), do: broadcast({:step, request_id, step})

  @doc """
  Announces a piece of the reply as it streams.
  """
  @spec delta(String.t(), integer(), String.t()) :: :ok
  def delta(request_id, seq, text), do: broadcast({:delta, request_id, seq, text})

  @doc """
  Announces Dobby's finished reply.
  """
  @spec replied(Message.t()) :: :ok
  def replied(%Message{} = message), do: broadcast({:replied, message})

  @doc """
  Announces a change to the house, whatever caused it.
  """
  @spec system_line(Message.t()) :: :ok
  def system_line(%Message{} = message), do: broadcast({:system_line, message})

  defp broadcast(payload), do: Phoenix.PubSub.broadcast(Dobby.PubSub, @topic, payload)
end
