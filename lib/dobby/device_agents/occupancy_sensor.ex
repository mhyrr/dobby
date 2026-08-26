defmodule Dobby.DeviceAgents.OccupancySensor do
  @moduledoc """
  A motion, occupancy, or presence sensor, which only ever reports.

  Three HA device classes, one household question — "is anyone there" — so
  they share a type rather than getting one each: a PIR, an mmWave sensor,
  and a phone-presence entity differ in mechanism, and the mechanism is
  exactly what Dobby's semantic layer exists to not care about.

  The discovery judgment is the part with teeth. A motion sensor that shares
  an HA device with a camera or doorbell is *that* device's motion — its
  agent binds it — and proposing it separately would give the household two
  names for one corner of the porch. `discovery_bindings/2` yields in that
  case, which is why this read-only type implements a callback most
  single-entity types leave to the default.
  """

  use Jido.Agent,
    name: "occupancy_sensor",
    description: "Reports whether a household area is occupied",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.OccupancySensor.SyncState}],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      occupied: [type: {:or, [:boolean, nil]}, default: nil],
      settings: [type: :map, default: %{}]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "occupancy_sensor"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity) do
    Entity.domain(entity) == "binary_sensor" and
      entity.device_class in ["motion", "occupancy", "presence"]
  end

  @impl Dobby.DeviceAgent
  def discovery_bindings(anchor, related) do
    if Enum.any?(related, &(Entity.domain(&1) in ["camera", "event"])) do
      :ignore
    else
      {:ok, %{occupancy: anchor.entity_id}}
    end
  end

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:occupancy])

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.OccupancySensorGetStatus]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:occupancy]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.OccupancySensor.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :occupancy)
end
