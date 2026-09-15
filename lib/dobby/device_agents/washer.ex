defmodule Dobby.DeviceAgents.Washer do
  @moduledoc """
  A washer reports its own laundry cycle, even in a stacked pair.

  Cycle progress, remaining time, and remote readiness are observations, not
  permission to start a load. This surface is read-only until the appliance's
  controls and interlocks are verified. Remaining time keeps HA's reported
  unit and never becomes a finish-time prediction made by the model.

  Bindings are explicit: a renamed HA sensor cannot establish appliance type.
  See `docs/appliance-research.md` for integration evidence and setup.
  """

  use Jido.Agent,
    name: "washer",
    description: "Reports the washer cycle, door, and remote readiness",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.Washer.SyncState}],
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
    operation_state: :text,
    program: :text,
    door_open: :door,
    progress: :percentage,
    remaining_time: :duration,
    finish_at: :timestamp,
    remote_start_allowed: :boolean,
    remote_control_allowed: :boolean
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "washer"

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
  def tools, do: [Dobby.Tools.WasherGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :washer)

  @doc false
  def sync(params, state), do: ApplianceReadings.sync(params, state, @reading_types, :washer)
end
