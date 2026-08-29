defmodule Dobby.DeviceAgents.Fan do
  @moduledoc """
  A fan, as Dobby understands one (design §4.2, §4.3).

  Deterministic and vendor-free, like `Light`: this module knows what a *fan*
  means, and Home Assistant knows which radio it is on. It is a separate type
  from `PowerSwitch` even though both turn on and off, because a fan has a
  speed and the household talks about it — "half speed" is a fan sentence
  with no switch equivalent.

  Whether speed control exists is *discovered*, not declared: HA's
  `SET_SPEED` feature bit is the hardware's word, and a fan that only knows
  on/off cannot be asked for a percentage a manifest promised. The surface is
  deliberately percentage-only. HA also carries preset modes, direction, and
  oscillation, and all three were left out on purpose: percentage is the one
  speed contract every HA fan speaks, while preset strings are each vendor's
  own vocabulary — binding them would put brand words back into a library
  built to keep them out.
  """

  use Jido.Agent,
    name: "fan",
    description: "Reports and controls a household fan",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Fan.SyncState},
      {"fan.set_power", Dobby.DeviceAgents.Fan.SetPower},
      {"fan.set_speed", Dobby.DeviceAgents.Fan.SetSpeed}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
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
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "fan"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Entity.domain(entity) == "fan"

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:fan])

  @impl Dobby.DeviceAgent
  def tools do
    [
      Dobby.Tools.FanGetStatus,
      Dobby.Tools.FanTurnOn,
      Dobby.Tools.FanTurnOff,
      Dobby.Tools.FanSetSpeed
    ]
  end

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:fan]

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{
      set_power: {"fan.set_power", Dobby.DeviceAgents.Fan.SetPower},
      set_speed: {"fan.set_speed", Dobby.DeviceAgents.Fan.SetSpeed}
    }

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Fan.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute in [:power, :speed_percent]

  @impl Dobby.DeviceAgent
  def command_arrived?(%{result: :accepted, action: :set_power, power: expected}, snapshot),
    do: snapshot.power == expected

  def command_arrived?(
        %{result: :accepted, action: :set_speed, speed_percent: expected},
        snapshot
      ),
      do: snapshot.speed_percent == expected

  def command_arrived?(_command, _snapshot), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :fan)
end
