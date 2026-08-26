defmodule Dobby.HomeAssistant.Connection do
  @moduledoc """
  Whether Home Assistant is actually answering (TK-016).

  The client process being alive and the house being reachable are two
  different facts, and until this module there was only the first one: a client
  sitting in its reconnect backoff looked exactly like a client talking to the
  house. Two surfaces want the second fact — the health list and the topology
  panel — so it is published once, here.

  **A transition, not a question.** The client announces `:connected` and
  `:reconnecting` as they happen, and the last one stands in a
  `:persistent_term` cell that anybody may read. Asking the client itself would
  be a synchronous call into the process whose trouble is the subject of the
  question — and a client that has *died* cannot answer at all, which is
  exactly the state a health panel exists to show.

  `:persistent_term` because the write is rare (a real transition, not a poll)
  and the read is on every render. The values are atoms, which are immediate
  terms, so replacing one costs no global collection.

  `:disconnected` is never published. It is what a *missing client* reads as,
  derived from the process registry at read time, which is the one state that
  cannot be announced by the process it is about.
  """

  @type status :: :connected | :reconnecting | :disconnected

  @topic "dobby:home_assistant"

  @doc """
  The PubSub topic carrying connection transitions.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the calling process to connection transitions.

      {:home_assistant, :connected}      the client authenticated
      {:home_assistant, :reconnecting}   it lost the connection, or never had one

  The status is carried for readability; a subscriber that wants the whole
  truth calls `status/0` when one arrives, since a client that has *died*
  cannot send anything.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Dobby.PubSub, @topic)

  @doc """
  Announces a transition, if it is one.

  Idempotent by design: the client calls this on every reconnect attempt and
  every authenticated connection, and only a change reaches the topic. Keyed by
  the client module so the fake and the real client are two separate facts —
  a box happily talking to the fake is a box that is not talking to the house.
  """
  @spec publish(module(), status()) :: :ok
  def publish(module, status) when status in [:connected, :reconnecting] do
    # Only the process actually holding the module's name may announce for it.
    # The client test rig starts anonymous clients by the handful, all of this
    # module — a harness client speaking for the house would overwrite the one
    # fact this cell exists to hold.
    if Process.whereis(module) == self() and stored(module) != status do
      :persistent_term.put(key(module), status)
      Phoenix.PubSub.broadcast(Dobby.PubSub, @topic, {:home_assistant, status})
    end

    :ok
  end

  @doc """
  What the configured client's connection is doing right now.

  A client that is not running is `:disconnected` whatever it last said, so a
  stale cell can never outlive the process that wrote it.
  """
  @spec status(module()) :: status()
  def status(module \\ Dobby.HomeAssistant.impl()) do
    if is_pid(Process.whereis(module)), do: stored(module), else: :disconnected
  end

  # A live client that has announced nothing has not authenticated yet, which
  # is what it is doing about it.
  defp stored(module), do: :persistent_term.get(key(module), :reconnecting)

  defp key(module), do: {__MODULE__, module}
end
