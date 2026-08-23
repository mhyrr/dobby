defmodule Dobby.DeviceAgents.Camera.SyncState do
  @moduledoc "Translates camera and motion entities into one camera snapshot."

  use Jido.Action,
    name: "camera_sync_state",
    description: "Applies a Home Assistant state change to a camera",
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
      type: :camera,
      available: state.available,
      activity: state.activity,
      motion: state.motion
    }
  end

  defp update(%{camera: entity_id}, %{entity_id: entity_id, state: state}) do
    %{available: available?(state), activity: activity(state)}
  end

  defp update(%{motion: entity_id}, %{entity_id: entity_id, state: state}) do
    %{motion: binary_state(state)}
  end

  defp update(_bindings, _params), do: %{}

  defp available?(state), do: state not in [nil, "unavailable", "unknown"]

  defp activity("streaming"), do: :streaming
  defp activity("recording"), do: :recording
  defp activity("idle"), do: :idle
  defp activity(_state), do: nil

  defp binary_state("on"), do: true
  defp binary_state("off"), do: false
  defp binary_state(_state), do: nil
end
