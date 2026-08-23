defmodule Dobby.DeviceAgents.Doorbell.SyncState do
  @moduledoc "Translates a doorbell's event, camera, and motion entities into one snapshot."

  use Jido.Action,
    name: "doorbell_sync_state",
    description: "Applies a Home Assistant state change to a doorbell",
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
    next = update(previous.bindings, params)
    keys = Map.keys(next)

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        merged = Map.merge(previous, next)

        {:ok, next,
         [DeviceEvents.emit(previous.dobby_id, snapshot(merged), changed: changed, moved: moved)]}
    end
  end

  @spec snapshot(map()) :: map()
  def snapshot(state) do
    %{
      id: state.dobby_id,
      name: state.name,
      type: :doorbell,
      available: state.available,
      last_event: state.last_event,
      last_event_at: state.last_event_at,
      camera_available: state.camera_available,
      motion: state.motion
    }
  end

  defp update(%{event: entity_id}, %{entity_id: entity_id} = params) do
    %{
      available: available?(params.state),
      last_event: text(params.attributes["event_type"]),
      last_event_at: text(params.state)
    }
  end

  defp update(%{camera: entity_id}, %{entity_id: entity_id, state: state}) do
    %{camera_available: available?(state)}
  end

  defp update(%{motion: entity_id}, %{entity_id: entity_id, state: state}) do
    %{motion: binary_state(state)}
  end

  defp update(_bindings, _params), do: %{}

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]

  defp binary_state("on"), do: true
  defp binary_state("off"), do: false
  defp binary_state(_state), do: nil

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil
end
