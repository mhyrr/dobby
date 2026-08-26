defmodule Dobby.DeviceAgents.Speaker do
  @moduledoc """
  A household speaker, independent of its vendor (TK-014).

  Sonos, Cast audio, and a Matter speaker reach Dobby through the same Home
  Assistant `media_player` contract. This agent keeps the first dependable
  surface small: playback state, volume, mute, current media, play, and pause.
  Queues, grouping, and announcements need more than one portable HA contract
  and wait for a house to earn them.
  """

  use Jido.Agent,
    name: "speaker",
    description: "Reports and controls a household speaker",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Speaker.SyncState},
      {"speaker.set_playback", Dobby.DeviceAgents.Speaker.SetPlayback},
      {"speaker.set_volume", Dobby.DeviceAgents.Speaker.SetVolume}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      playback: [type: {:or, [:atom, nil]}, default: nil],
      volume_percent: [type: {:or, [:integer, nil]}, default: nil],
      muted: [type: {:or, [:boolean, nil]}, default: nil],
      media_title: [type: {:or, [:string, nil]}, default: nil],
      capabilities: [type: :map, default: %{}],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device

  @impl Dobby.DeviceAgent
  def config_type, do: "speaker"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity) do
    Dobby.HomeAssistant.Entity.domain(entity) == "media_player" and
      entity.device_class in [nil, "speaker"]
  end

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:media_player])

  @impl Dobby.DeviceAgent
  def tools do
    [
      Dobby.Tools.SpeakerGetStatus,
      Dobby.Tools.SpeakerPlay,
      Dobby.Tools.SpeakerPause,
      Dobby.Tools.SpeakerSetVolume
    ]
  end

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:media_player]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Speaker.SyncState

  # Deliberately silent in the thread, unlike the other write-capable types
  # (Greg, 2026-08-23). Home Assistant cannot tell the Sonos app from a hand
  # on the device, and a speaker moves with every track — marking playback
  # or volume as interventions would narrate normal listening. What the
  # thread should say about music is TK-029's design question; nothing here
  # changes until it is answered.
  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device),
    do: Dobby.DeviceAgent.initial_state(device, :media_player)
end
