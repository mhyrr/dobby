defmodule Dobby.DeviceAgents.Oven do
  @moduledoc """
  An oven cavity, distinct from the cooktop in the same range.

  Temperature and target temperature are separate readings. Neither an oven
  temperature nor remote readiness proves permission to energize a burner.
  This type exposes observations only until the appliance's controls have
  been verified. Bind a second cavity as a separate oven.

  Bindings are explicit because HA has no appliance-specific sensor domain.
  Guessing from a renamed entity would mistake a room sensor for an appliance.
  See `docs/appliance-research.md` for the integration evidence and next steps.
  """

  use Jido.Agent,
    name: "oven",
    description: "Reports oven temperature, setpoint, door, and remote readiness",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.Oven.SyncState}],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      bindings: [type: :map, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      readings: [type: :map, default: %{}],
      units: [type: :map, default: %{}],
      settings: [type: :map, default: %{}]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.DeviceAgents.ApplianceReadings

  @reading_types [
    temperature: :temperature,
    target_temperature: :temperature,
    probe_temperature: :temperature,
    probe_target_temperature: :temperature,
    door_open: :door,
    running: :boolean,
    at_temperature: :boolean,
    remote_start_allowed: :boolean,
    operation_state: :text
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "oven"

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def matches_entity?(_entity), do: false

  @impl Dobby.DeviceAgent
  def discovery_bindings(_anchor, _related), do: :ignore

  @impl Dobby.DeviceAgent
  def validate_device(device), do: ApplianceReadings.validate_device(device, @reading_types)

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: Keyword.keys(@reading_types)

  @impl Dobby.DeviceAgent
  def observables, do: ApplianceReadings.observables(@reading_types)

  @impl Dobby.DeviceAgent
  def initial_state(device), do: ApplianceReadings.initial_state(device)

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.OvenGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :oven)

  @doc false
  def sync(params, state), do: ApplianceReadings.sync(params, state, @reading_types, :oven)
end
