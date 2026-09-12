defmodule Dobby.DeviceAgents.Humidifier do
  @moduledoc """
  A household humidifier over HA's standard humidity interface.

  Its semantic identity is independent of vendor. HA device class distinguishes
  adding moisture from drying; a missing class never authorizes a command.
  The shared humidity interpreter owns ranges, capabilities, and observations.
  """
  use Jido.Agent,
    name: "humidifier",
    description: "Reports and controls a household humidifier",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Humidifier.SyncState},
      {"humidifier.set_power", Dobby.DeviceAgents.Humidifier.SetPower},
      {"humidifier.set_humidity", Dobby.DeviceAgents.Humidifier.SetHumidity},
      {"humidifier.set_mode", Dobby.DeviceAgents.Humidifier.SetMode}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      device_type: [type: :atom, default: :humidifier],
      device_class: [type: {:or, [:string, nil]}, default: nil],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      power: [type: {:or, [:atom, nil]}, default: nil],
      current_humidity_percent: [type: {:or, [:integer, :float, nil]}, default: nil],
      target_humidity_percent: [type: {:or, [:integer, :float, nil]}, default: nil],
      action: [type: {:or, [:string, nil]}, default: nil],
      mode: [type: {:or, [:string, nil]}, default: nil],
      capabilities: [type: {:or, [:map, nil]}, default: nil],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent
  alias Dobby.DeviceAgents.Humidity

  @impl Dobby.DeviceAgent
  def config_type, do: "humidifier"
  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Humidity.matches_entity?(entity, :humidifier)
  @impl Dobby.DeviceAgent
  defdelegate config_schema(), to: Humidity
  @impl Dobby.DeviceAgent
  defdelegate validate_device(device), to: Humidity
  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:humidifier]
  @impl Dobby.DeviceAgent
  def initial_state(device), do: Humidity.initial_state(device, :humidifier)
  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Humidity
  @impl Dobby.DeviceAgent
  defdelegate command_arrived?(command, snapshot), to: Humidity
  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute in [:power, :target_humidity_percent, :mode]
  @impl Dobby.DeviceAgent
  def tools,
    do: [
      Dobby.Tools.HumidifierGetStatus,
      Dobby.Tools.HumidifierTurnOn,
      Dobby.Tools.HumidifierTurnOff,
      Dobby.Tools.HumidifierSetHumidity,
      Dobby.Tools.HumidifierSetMode
    ]

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{
      set_power: {"humidifier.set_power", Dobby.DeviceAgents.Humidifier.SetPower},
      set_humidity: {"humidifier.set_humidity", Dobby.DeviceAgents.Humidifier.SetHumidity},
      set_mode: {"humidifier.set_mode", Dobby.DeviceAgents.Humidifier.SetMode}
    }
end
