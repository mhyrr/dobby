defmodule Dobby.DeviceAgents.AccessCover.SyncState do
  @moduledoc "Translates Home Assistant cover state into access-cover state."

  use Jido.Action,
    name: "access_cover_sync_state",
    description: "Applies a Home Assistant state change to an access cover",
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

    next = %{
      available: available?(params.state),
      cover_state: cover_state(params.state),
      position: position(params.attributes["current_position"])
    }

    keys = [:available, :cover_state, :position]

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
      type: :access_cover,
      available: next.available,
      cover_state: next.cover_state,
      position: next.position
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]

  defp cover_state("open"), do: :open
  defp cover_state("closed"), do: :closed
  defp cover_state("opening"), do: :opening
  defp cover_state("closing"), do: :closing
  defp cover_state("stopped"), do: :stopped
  defp cover_state(_state), do: nil

  defp position(value) when is_integer(value) and value in 0..100, do: value
  defp position(value) when is_float(value) and value >= 0 and value <= 100, do: round(value)
  defp position(_value), do: nil

  # `:closing` is the echo still in flight; `:closed` is it landing.
  defp commanded?(%{last_command: %{result: :accepted, action: :close}}, next),
    do: next.cover_state in [:closing, :closed]

  defp commanded?(_previous, _next), do: false

  # One-shot for the same reason the lock's echo is (see Lock.SyncState):
  # the only closed value is :closed, so a standing accepted command would
  # swallow every hand-close of the garage forever.
  defp consume_echo(%{cover_state: :closed} = next, true),
    do: Map.put(next, :last_command, nil)

  defp consume_echo(next, _commanded?), do: next
end
