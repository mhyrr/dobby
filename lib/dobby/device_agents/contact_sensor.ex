defmodule Dobby.DeviceAgents.ContactSensor do
  @moduledoc """
  A door, window, or garage contact, which only ever reports.

  A read-only device earns its agent by feeding the world model: "is the
  patio door open" is a question the thread gets asked, and the direct path
  and the board need the same answer with no model involved.

  This is deliberately not a generic sensor type, though HA's
  `binary_sensor` domain would let one exist. The domain holds doors, smoke
  alarms, motion, and printer connectivity in one bucket, and a generic
  `SensorAgent` would erase exactly the distinction a household runs on —
  which of those facts matters, and how much. The device class carries the
  consequence, so each class family is its own Dobby type: contacts here,
  presence in `OccupancySensor`, hazards in `SafetySensor`, connectivity in
  `WifiEndpoint`.
  """

  use Jido.Agent,
    name: "contact_sensor",
    description: "Reports whether a household opening is open or closed",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.ContactSensor.SyncState}],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      open: [type: {:or, [:boolean, nil]}, default: nil],
      settings: [type: :map, default: %{}]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "contact_sensor"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity) do
    Entity.domain(entity) == "binary_sensor" and
      entity.device_class in ["door", "window", "garage_door", "opening"]
  end

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:contact])

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.ContactSensorGetStatus]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:contact]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.ContactSensor.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :contact)
end
