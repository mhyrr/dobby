defmodule Dobby.DeviceEvents do
  @moduledoc """
  The `dobby.device.state_changed` seam.

  Device agents emit one event stream; it has two consumers (design §7): the
  Phoenix thread and cards, and — once it exists — `DobbyAgent`'s world model.
  This module is where both sides agree on the topic and the payload, so the
  agreement lives in code rather than in two places that drift.
  """

  @topic "dobby:devices"

  @doc """
  The PubSub topic carrying device state changes.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the calling process to device state changes.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Dobby.PubSub, @topic)

  @doc """
  The dispatch config device agents attach to their emitted signal.

  One event stream, two consumers (design §7): the Phoenix thread and cards
  over PubSub, and `DobbyAgent`'s world model directly. The second target is
  resolved at emit time and dropped when no `DobbyAgent` is running, so the
  deterministic layer stands on its own — which is the point of it.
  """
  @spec dispatch() :: [{atom(), keyword()}]
  def dispatch do
    pubsub = {:pubsub, target: Dobby.PubSub, topic: @topic}

    case Dobby.Jido.whereis(Dobby.DobbyAgent.id()) do
      pid when is_pid(pid) -> [pubsub, {:pid, target: pid}]
      nil -> [pubsub]
    end
  end

  @doc """
  Builds the emit directive for a device whose state meaningfully changed.

  `snapshot` is the device's public state — what the cards render and what the
  model is told the house currently looks like.
  """
  @spec emit(String.t(), map()) :: Jido.Agent.Directive.Emit.t()
  def emit(dobby_id, snapshot) do
    signal =
      Jido.Signal.new!("dobby.device.state_changed", %{
        device: dobby_id,
        snapshot: snapshot
      })

    %Jido.Agent.Directive.Emit{signal: signal, dispatch: dispatch()}
  end
end
