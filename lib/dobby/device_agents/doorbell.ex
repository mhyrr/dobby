defmodule Dobby.DeviceAgents.Doorbell do
  @moduledoc """
  A doorbell assembled from the entities Home Assistant assigns to one device.

  The event entity is the identity. A camera and motion sensor enrich it when
  present. Brands remain Home Assistant's concern; Dobby binds the stable HA
  contract and reports the last event without creating a media path.
  """

  use Jido.Agent,
    name: "doorbell",
    description: "Reports a doorbell event, camera availability, and motion",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.Doorbell.SyncState}],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      bindings: [type: :map, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      last_event: [type: {:or, [:string, nil]}, default: nil],
      last_event_at: [type: {:or, [:string, nil]}, default: nil],
      camera_available: [type: {:or, [:boolean, nil]}, default: nil],
      motion: [type: {:or, [:boolean, nil]}, default: nil],
      settings: [type: :map, default: %{}]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "doorbell"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity),
    do: Entity.domain(entity) == "event" and entity.device_class == "doorbell"

  @impl Dobby.DeviceAgent
  def discovery_bindings(anchor, related) do
    bindings = %{event: anchor.entity_id}

    bindings =
      case Enum.find(related, &(Entity.domain(&1) == "camera")) do
        nil -> bindings
        entity -> Map.put(bindings, :camera, entity.entity_id)
      end

    bindings =
      case Enum.find(related, &motion_sensor?/1) do
        nil -> bindings
        entity -> Map.put(bindings, :motion, entity.entity_id)
      end

    {:ok, bindings}
  end

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:event], [:camera, :motion])

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.DoorbellGetStatus]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:event, :camera, :motion]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Doorbell.SyncState

  # A ring is a person at the door commanding the bell — the cleanest
  # "somebody did something at the device" in the library, so it belongs in
  # the thread (Greg, 2026-08-23). The timestamp carries the ring:
  # `last_event` stays "ring" between two rings and would only announce the
  # first. Whether the house also says something out loud is the owner's
  # call, deferred to voice-channel config (TK-028). Camera and motion
  # movements stay observed, off the thread.
  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute == :last_event_at

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device)

  defp motion_sensor?(entity) do
    Entity.domain(entity) == "binary_sensor" and
      entity.device_class in ["motion", "occupancy"]
  end
end
