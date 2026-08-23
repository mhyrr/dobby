defmodule Dobby.DeviceAgents.Shade.SyncState do
  @moduledoc "Translates Home Assistant cover state into household shade state."

  use Jido.Action,
    name: "shade_sync_state",
    description: "Applies a Home Assistant state change to a shade",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents

  @set_position 4

  @impl true
  def run(params, context) do
    previous = context.state

    next = %{
      available: available?(params.state),
      shade_state: shade_state(params.state),
      position: position(params.attributes["current_position"]),
      supports_position: supports?(params.attributes["supported_features"], @set_position)
    }

    keys = [:available, :shade_state, :position, :supports_position]

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved,
             commanded?: commanded?(previous, next)
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
      type: :shade,
      available: next.available,
      shade_state: next.shade_state,
      position: next.position,
      supports_position: next.supports_position
    }
  end

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]
  defp shade_state("open"), do: :open
  defp shade_state("closed"), do: :closed
  defp shade_state("opening"), do: :opening
  defp shade_state("closing"), do: :closing
  defp shade_state("stopped"), do: :stopped
  defp shade_state(_state), do: nil
  defp position(value) when is_integer(value) and value in 0..100, do: value
  defp position(value) when is_float(value) and value >= 0 and value <= 100, do: round(value)
  defp position(_value), do: nil

  defp supports?(features, flag) when is_integer(features),
    do: Bitwise.band(features, flag) == flag

  defp supports?(_features, _flag), do: false

  defp commanded?(%{last_command: %{result: :accepted, action: :open}}, next),
    do: next.shade_state == :open

  defp commanded?(%{last_command: %{result: :accepted, action: :close}}, next),
    do: next.shade_state == :closed

  defp commanded?(%{last_command: %{result: :accepted, position: position}}, next),
    do: next.position == position

  defp commanded?(_previous, _next), do: false
end
