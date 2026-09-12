defmodule Dobby.DeviceAgents.Cooktop do
  @moduledoc """
  One cooktop entry represents one heating zone, named by its position.

  Active heating and residual surface heat are independent observations. An
  inactive zone can remain hot, and a missing heat reading cannot prove it is
  safe to touch. A reported percentage is not a temperature or a universal
  stove knob scale. Explicit bindings expose readings without a power command.
  """

  use Jido.Agent,
    name: "cooktop",
    description: "Reports one cooktop zone activity, residual heat, and power level",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.Cooktop.SyncState}],
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
    active: :boolean,
    hot_surface: :boolean,
    power_level: :percentage
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "cooktop"

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
  def tools, do: [Dobby.Tools.CooktopGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :cooktop)

  @doc false
  def sync(params, state), do: ApplianceReadings.sync(params, state, @reading_types, :cooktop)
end
