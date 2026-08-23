defmodule Dobby.DeviceAgents.Lock.SyncState do
  @moduledoc "Translates Home Assistant lock state into Dobby lock state."

  use Jido.Action,
    name: "lock_sync_state",
    description: "Applies a Home Assistant state change to a lock",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents

  @impl true
  def run(params, context) do
    previous = context.state
    next = %{available: available?(params.state), lock_state: lock_state(params.state)}
    keys = [:available, :lock_state]
    commanded? = commanded?(previous, next)

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, consume_echo(next, commanded?)}

      %{changed: changed, moved: moved} ->
        {:ok, consume_echo(next, commanded?),
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved,
             commanded?: commanded?
           )
         ]}
    end
  end

  @spec snapshot(map()) :: map()
  def snapshot(state), do: snapshot(state, state)

  defp snapshot(previous, next) do
    %{
      id: previous.dobby_id,
      name: previous.name,
      type: :lock,
      available: next.available,
      lock_state: next.lock_state
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]

  defp lock_state("locked"), do: :locked
  defp lock_state("unlocked"), do: :unlocked
  defp lock_state("locking"), do: :locking
  defp lock_state("unlocking"), do: :unlocking
  defp lock_state("jammed"), do: :jammed
  defp lock_state("open"), do: :open
  defp lock_state(_state), do: nil

  # `:locking` is the echo still in flight on hardware that reports it;
  # `:locked` is the echo landing.
  defp commanded?(%{last_command: %{result: :accepted, action: :secure}}, next),
    do: next.lock_state in [:locking, :locked]

  defp commanded?(_previous, _next), do: false

  # The echo is one-shot, where the thermostat's is not. Its rounding misses
  # only a hand returning the dial to one exact number; a lock's only secure
  # value is :locked, so a standing accepted command would swallow every
  # hand-lock forever. Consuming the command once its echo lands means every
  # later change is somebody's hand, and the thread lists it (Greg,
  # 2026-08-23).
  defp consume_echo(%{lock_state: :locked} = next, true),
    do: Map.put(next, :last_command, nil)

  defp consume_echo(next, _commanded?), do: next
end
