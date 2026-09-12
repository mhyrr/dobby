defmodule Dobby.DeviceAgents.Microwave do
  @moduledoc """
  A microwave reports a cooking cycle without granting permission to start it.

  Remaining time retains its reported unit. Zero remaining time does not
  declare completion, and a finish timestamp is the appliance report rather
  than a model prediction. Door and remote readiness remain separate facts.
  Explicit scalar bindings supply observations only.
  """

  use Jido.Agent,
    name: "microwave",
    description: "Reports microwave activity, door, remaining time, and remote readiness",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.Microwave.SyncState}],
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
    door_open: :door,
    remaining_time: :duration,
    finish_at: :timestamp,
    remote_start_allowed: :boolean
  ]

  @impl Dobby.DeviceAgent
  def config_type, do: "microwave"

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
  def tools, do: [Dobby.Tools.MicrowaveGetStatus]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def snapshot(state), do: ApplianceReadings.snapshot(state, :microwave)

  @doc false
  def sync(params, state), do: ApplianceReadings.sync(params, state, @reading_types, :microwave)
end
