defmodule Dobby.DeviceAgents.Dishwasher do
  @moduledoc """
  A dishwasher is one household device even when HA exposes many entities.

  This first surface reports the cycle and permission flags. A remote-ready
  reading is not a start command. Program control needs the actual appliance's
  options and interlocks before a write tool can be added.

  Bindings are explicit because HA has no appliance-specific sensor domain.
  Guessing from a renamed entity would mistake a room sensor for an appliance.
  See `docs/appliance-research.md` for the integration evidence and next steps.
  """

  use Jido.Agent,
    name: "dishwasher",
    description: "Reports the dishwasher cycle, door, and remote readiness",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.Dishwasher.SyncState}],
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
    finish_at: :timestamp,
    remote_start_allowed: :boolean,
    remote_control_allowed: :boolean
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "dishwasher"

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
  def initial_state(device), do: ApplianceReadings.initial_state(device)

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.DishwasherGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :dishwasher)

  @doc false
  def sync(params, state), do: ApplianceReadings.sync(params, state, @reading_types, :dishwasher)
end
