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

  The three options exist for one consumer, `Dobby.Interventions.Watcher`,
  which has to tell "somebody turned the dial in the hallway" from "the room
  got a degree colder" (design §10.3) — and Home Assistant reports neither.

      changed      everything that differs; what the log records
      moved        the subset that went from one known value to another
      commanded?   whether this house asked for it

  `moved` and `changed` differ at boot, when a device reports for the first
  time: nothing moved, because there was nothing to move from. `commanded?` is
  what keeps Home Assistant's echo of our own command from reading as a second
  event — see `Dobby.DeviceAgents.Thermostat.SyncState.commanded?/2`.
  """
  @spec emit(String.t(), map(), keyword()) :: Jido.Agent.Directive.Emit.t()
  def emit(dobby_id, snapshot, opts \\ []) do
    signal =
      Jido.Signal.new!("dobby.device.state_changed", %{
        device: dobby_id,
        snapshot: snapshot,
        changed: Keyword.get(opts, :changed, []),
        moved: Keyword.get(opts, :moved, []),
        commanded?: Keyword.get(opts, :commanded?, false)
      })

    %Jido.Agent.Directive.Emit{signal: signal, dispatch: dispatch()}
  end
end
