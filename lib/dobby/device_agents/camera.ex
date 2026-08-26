defmodule Dobby.DeviceAgents.Camera do
  @moduledoc """
  A household camera viewed through Home Assistant (TK-014).

  The camera stays read-only. Streaming media and snapshots need a separate
  authenticated media path; pretending they are ordinary service calls would
  leak Home Assistant transport into the language layer.
  """

  use Jido.Agent,
    name: "camera",
    description: "Reports a household camera and its related motion sensor",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.Camera.SyncState}],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      bindings: [type: :map, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      activity: [type: {:or, [:atom, nil]}, default: nil],
      motion: [type: {:or, [:boolean, nil]}, default: nil],
      settings: [type: :map, default: %{}]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "camera"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Entity.domain(entity) == "camera"

  @impl Dobby.DeviceAgent
  def discovery_bindings(anchor, related) do
    if Enum.any?(related, &doorbell_event?/1) do
      :ignore
    else
      {:ok, optional_motion(%{camera: anchor.entity_id}, related)}
    end
  end

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:camera], [:motion])

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.CameraGetStatus]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:camera, :motion]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Camera.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device)

  defp optional_motion(bindings, related) do
    case Enum.find(related, &motion_sensor?/1) do
      nil -> bindings
      entity -> Map.put(bindings, :motion, entity.entity_id)
    end
  end

  defp motion_sensor?(entity) do
    Entity.domain(entity) == "binary_sensor" and
      entity.device_class in ["motion", "occupancy"]
  end

  defp doorbell_event?(entity) do
    Entity.domain(entity) == "event" and entity.device_class == "doorbell"
  end
end
