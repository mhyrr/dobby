defmodule Dobby.DeviceAgents.Speaker.SyncState do
  @moduledoc """
  Translates a Home Assistant media-player state into speaker state.

  Volume is kept as the percentage a person says rather than HA's zero-to-one
  wire value. Media metadata is observed and never treated as a command.
  """

  use Jido.Action,
    name: "speaker_sync_state",
    description: "Applies a Home Assistant state change to a speaker",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents

  # Home Assistant's MediaPlayerEntityFeature bit values. Keep the names at
  # the boundary so a capability stays a word everywhere above it.
  @pause 1
  @volume_set 4
  @play 16_384

  @impl true
  def run(params, context) do
    previous = context.state

    next = %{
      available: params.state not in [nil, "unavailable", "unknown"],
      playback: playback(params.state),
      volume_percent: volume(params.attributes["volume_level"]),
      muted: boolean(params.attributes["is_volume_muted"]),
      media_title: text(params.attributes["media_title"]),
      capabilities: capabilities(previous.capabilities, params.attributes["supported_features"])
    }

    # Capabilities stay out of the changed/moved calculus, as on the light:
    # discovery is the house learning what the speaker can be asked, not
    # something that happened in the house.
    keys = [:available, :playback, :volume_percent, :muted, :media_title]

    case DeviceAgent.changes(previous, next, keys) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved
           )
         ]}
    end
  end

  @spec snapshot(map()) :: map()
  def snapshot(state), do: snapshot(state, state)

  @spec snapshot(map(), map()) :: map()
  def snapshot(previous, next) do
    %{
      id: previous.dobby_id,
      name: previous.name,
      type: :speaker,
      available: next.available,
      playback: next.playback,
      volume_percent: next.volume_percent,
      muted: next.muted,
      media_title: next.media_title,
      capabilities: next.capabilities
    }
  end

  defp playback("playing"), do: :playing
  defp playback("paused"), do: :paused
  defp playback("idle"), do: :idle
  defp playback("off"), do: :off
  defp playback("buffering"), do: :buffering
  defp playback(_state), do: nil

  defp volume(level) when is_number(level), do: round(level * 100)
  defp volume(_level), do: nil

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: nil

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  defp capabilities(_previous, features) when is_integer(features) do
    %{
      play: supports?(features, @play),
      pause: supports?(features, @pause),
      volume: supports?(features, @volume_set)
    }
  end

  defp capabilities(previous, _features), do: previous || %{}

  defp supports?(features, flag), do: Bitwise.band(features, flag) == flag
end
