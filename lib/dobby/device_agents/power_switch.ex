defmodule Dobby.DeviceAgents.PowerSwitch do
  @moduledoc """
  A generic Home Assistant switch for plugs, outlets, and relays.

  This type stays separate from Light even though both turn on and off. A
  switch can power a heater, pump, or appliance, so the household sees and
  names it as the thing it controls rather than as a bulb.
  """

  use Jido.Agent,
    name: "power_switch",
    description: "Reports and controls a household switch",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.PowerSwitch.SyncState},
      {"power_switch.set_power", Dobby.DeviceAgents.PowerSwitch.SetPower}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      power: [type: {:or, [:atom, nil]}, default: nil],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "power_switch"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Entity.domain(entity) == "switch"

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:switch])

  @impl Dobby.DeviceAgent
  def tools do
    [
      Dobby.Tools.PowerSwitchGetStatus,
      Dobby.Tools.PowerSwitchTurnOn,
      Dobby.Tools.PowerSwitchTurnOff
    ]
  end

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:switch]

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{set_power: {"power_switch.set_power", Dobby.DeviceAgents.PowerSwitch.SetPower}}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.PowerSwitch.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute == :power

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :switch)
end
