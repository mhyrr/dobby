defmodule Dobby.DeviceAgents.RangeHood do
  @moduledoc """
  A household range hood, controlled through HA's native fan interface.

  The manifest supplies its household role; fan entities have no reliable
  discriminator for that role. Optional filter readings do not establish fan
  availability. Commands retain the standard fan capability and range checks.
  """

  use Jido.Agent,
    name: "range_hood",
    description: "Reports and controls a household range hood",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.RangeHood.SyncState},
      {"range_hood.set_power", Dobby.DeviceAgents.Fan.SetPower},
      {"range_hood.set_speed", Dobby.DeviceAgents.Fan.SetSpeed}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      bindings: [type: :map, default: %{}],
      readings: [type: :map, default: %{}],
      units: [type: :map, default: %{}],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      power: [type: {:or, [:atom, nil]}, default: nil],
      speed_percent: [type: {:or, [:integer, nil]}, default: nil],
      supports_speed: [type: {:or, [:boolean, nil]}, default: nil],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.DeviceAgents.Ventilation

  @readings [filter_remaining: :percentage, filter_due: :boolean]

  @impl Dobby.DeviceAgent
  def config_type, do: "range_hood"

  @impl Dobby.DeviceAgent
  def matches_entity?(_entity), do: false

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Ventilation.validate_device(device, @readings)

  @impl Dobby.DeviceAgent
  def tools do
    [
      Dobby.Tools.RangeHoodGetStatus,
      Dobby.Tools.RangeHoodTurnOn,
      Dobby.Tools.RangeHoodTurnOff,
      Dobby.Tools.RangeHoodSetSpeed
    ]
  end

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:fan | Keyword.keys(@readings)]

  @doc false
  def reading_types, do: @readings

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{
      set_power: {"range_hood.set_power", Dobby.DeviceAgents.Fan.SetPower},
      set_speed: {"range_hood.set_speed", Dobby.DeviceAgents.Fan.SetSpeed}
    }

  @impl Dobby.DeviceAgent
  def snapshot(state), do: Ventilation.snapshot(state, :range_hood)

  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute in [:power, :speed_percent]

  @impl Dobby.DeviceAgent
  def command_arrived?(%{result: :accepted, action: :set_power, power: expected}, snapshot),
    do: snapshot.available == true and snapshot.power == expected

  def command_arrived?(
        %{result: :accepted, action: :set_speed, speed_percent: expected},
        snapshot
      ),
      do: snapshot.available == true and snapshot.speed_percent == expected

  def command_arrived?(_command, _snapshot), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Ventilation.initial_state(device)
end
