defmodule Dobby.CommandEvents do
  @moduledoc """
  The deterministic command-confirmation seam (TK-035).

  Device agents decide whether a command is allowed. The HACall executor then
  announces the expectation immediately before the network call, and announces
  a refusal if Home Assistant rejects it. `Dobby.Interventions.Watcher` owns
  the timer and compares later device snapshots against the device type's own
  answer to `c:Dobby.DeviceAgent.command_arrived?/2`.

  This is PubSub rather than a call into the watcher because the HACall runs in
  a device agent's directive drain. Waiting on the witness from that process
  would make a side record part of the command path it is only observing.
  """

  @topic "dobby:commands"

  @doc "Subscribes the calling process to command lifecycle events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Dobby.PubSub, @topic)

  @doc "Announces that an accepted command is about to reach Home Assistant."
  @spec expected(map()) :: :ok | {:error, term()}
  def expected(data), do: publish("dobby.command.expected", data)

  @doc "Announces that Home Assistant refused an accepted device command."
  @spec failed(map()) :: :ok | {:error, term()}
  def failed(data), do: publish("dobby.ha.call_failed", data)

  defp publish(type, data) do
    signal = Jido.Signal.new!(type, data)
    Phoenix.PubSub.broadcast(Dobby.PubSub, @topic, signal)
  end
end
