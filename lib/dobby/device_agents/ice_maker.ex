defmodule Dobby.DeviceAgents.IceMaker do
  @moduledoc """
  An ice maker reports production state and the supplies it needs.

  A full bin, missing water and a cleaning request are different facts. A bin
  that is not full may still be empty, so the status never invents an ice
  quantity. Explicit scalar bindings preserve those meanings without assuming
  an integration control domain. This contract only reads.
  """

  use Jido.Agent,
    name: "ice_maker",
    description: "Reports ice maker activity, bin, water, and maintenance",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.IceMaker.SyncState}],
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
    ice_full: :boolean,
    water_empty: :boolean,
    cleaning_required: :boolean
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "ice_maker"

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
  def tools, do: [Dobby.Tools.IceMakerGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :ice_maker)

  @doc false
  def sync(params, state), do: ApplianceReadings.sync(params, state, @reading_types, :ice_maker)
end
