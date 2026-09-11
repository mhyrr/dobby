defmodule Dobby.DeviceAgents.Refrigerator do
  @moduledoc """
  A refrigerator and its compartments are one household object.

  Reported temperatures and setpoints are different facts. Some integrations
  expose only setpoints, so those must never stand in for a missing reading.
  Display temperatures are identified as such: the integration does not prove
  that a display value is a fresh physical measurement. This type only reads.

  Bindings are explicit because HA has no appliance-specific sensor domain.
  Guessing from a renamed entity would mistake a room sensor for an appliance.
  See `docs/appliance-research.md` for the integration evidence and next steps.
  """

  use Jido.Agent,
    name: "refrigerator",
    description: "Reports refrigerator and freezer temperatures, targets, and doors",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.Refrigerator.SyncState}],
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
    refrigerator_display_temperature: :temperature,
    refrigerator_target_temperature: :temperature,
    freezer_display_temperature: :temperature,
    freezer_target_temperature: :temperature,
    crisper_target_temperature: :temperature,
    refrigerator_door_open: :door,
    freezer_door_open: :door
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "refrigerator"

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
  def tools, do: [Dobby.Tools.RefrigeratorGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :refrigerator)

  @doc false
  def sync(params, state),
    do: ApplianceReadings.sync(params, state, @reading_types, :refrigerator)
end
