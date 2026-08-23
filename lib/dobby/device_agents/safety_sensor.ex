defmodule Dobby.DeviceAgents.SafetySensor do
  @moduledoc """
  A read-only life-safety detector.

  Smoke, carbon monoxide, gas, moisture, heat, and cold alarms share an
  observation contract. Sirens and alarm panels do not; those are actuators
  and remain outside this type.
  """

  use Jido.Agent,
    name: "safety_sensor",
    description: "Reports a household safety alarm",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.SafetySensor.SyncState}],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      alarm: [type: {:or, [:boolean, nil]}, default: nil],
      hazard: [type: {:or, [:atom, nil]}, default: nil],
      settings: [type: :map, default: %{}]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @classes ~w(smoke carbon_monoxide gas moisture heat cold)

  @impl Dobby.DeviceAgent
  def config_type, do: "safety_sensor"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity),
    do: Entity.domain(entity) == "binary_sensor" and entity.device_class in @classes

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:alarm])

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.SafetySensorGetStatus]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:alarm]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.SafetySensor.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :alarm)
end
