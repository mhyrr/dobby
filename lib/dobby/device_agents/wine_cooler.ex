defmodule Dobby.DeviceAgents.WineCooler do
  @moduledoc """
  A wine cooler keeps measured temperatures distinct from stored targets.

  Single-zone and upper/lower-zone bindings share one appliance identity.
  Missing measurements stay unknown even when targets are known. Bind only
  actual measured temperatures to temperature readings; an integration display
  or setpoint is not evidence of a measurement. This contract only reads.
  """

  use Jido.Agent,
    name: "wine_cooler",
    description: "Reports wine cooler temperatures, targets, and door",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.WineCooler.SyncState}],
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
    upper_temperature: :temperature,
    lower_temperature: :temperature,
    upper_target_temperature: :temperature,
    lower_target_temperature: :temperature,
    door_open: :door
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "wine_cooler"

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
  def tools, do: [Dobby.Tools.WineCoolerGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :wine_cooler)

  @doc false
  def sync(params, state), do: ApplianceReadings.sync(params, state, @reading_types, :wine_cooler)
end
