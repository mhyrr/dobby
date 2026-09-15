defmodule Dobby.DeviceAgents.CoffeeMaker do
  @moduledoc """
  A coffee maker reports activity and what it needs before the next cup.

  Water, beans, grounds and cleaning are separate observations. A clear
  maintenance flag does not establish readiness to brew, and remote readiness
  is not a command. Explicit scalar bindings keep this contract independent of
  the integration that supplies the readings.
  """

  use Jido.Agent,
    name: "coffee_maker",
    description: "Reports coffee maker activity, supplies, and maintenance",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.CoffeeMaker.SyncState}],
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
    water_empty: :boolean,
    beans_empty: :boolean,
    grounds_full: :boolean,
    cleaning_required: :boolean,
    remote_start_allowed: :boolean
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "coffee_maker"

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
  def tools, do: [Dobby.Tools.CoffeeMakerGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :coffee_maker)

  @doc false
  def sync(params, state),
    do: ApplianceReadings.sync(params, state, @reading_types, :coffee_maker)
end
