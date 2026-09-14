defmodule Dobby.DeviceAgents.Dehumidifier do
  @moduledoc """
  A household dehumidifier over HA's standard humidity interface.

  Its semantic identity is independent of vendor. HA device class distinguishes
  adding moisture from drying; a missing class never authorizes a command.
  The shared humidity interpreter owns ranges, capabilities, and observations.
  """
  use Jido.Agent,
    name: "dehumidifier",
    description: "Reports and controls a household dehumidifier",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Dehumidifier.SyncState},
      {"dehumidifier.set_power", Dobby.DeviceAgents.Dehumidifier.SetPower},
      {"dehumidifier.set_humidity", Dobby.DeviceAgents.Dehumidifier.SetHumidity},
      {"dehumidifier.set_mode", Dobby.DeviceAgents.Dehumidifier.SetMode}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      device_type: [type: :atom, default: :dehumidifier],
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
  def config_type, do: "dehumidifier"
  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Humidity.matches_entity?(entity, :dehumidifier)
  @impl Dobby.DeviceAgent
  defdelegate config_schema(), to: Humidity
  @impl Dobby.DeviceAgent
  defdelegate validate_device(device), to: Humidity
  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:humidifier]
  @impl Dobby.DeviceAgent
  def initial_state(device), do: Humidity.initial_state(device, :dehumidifier)
  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Humidity

  @impl Dobby.DeviceAgent
  defdelegate controls(snapshot), to: Dobby.DeviceAgents.Humidity
  @impl Dobby.DeviceAgent
  defdelegate command_arrived?(command, snapshot), to: Humidity
  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute in [:power, :target_humidity_percent, :mode]
  @impl Dobby.DeviceAgent
  def tools,
    do: [
      Dobby.Tools.DehumidifierGetStatus,
      Dobby.Tools.DehumidifierTurnOn,
      Dobby.Tools.DehumidifierTurnOff,
      Dobby.Tools.DehumidifierSetHumidity,
      Dobby.Tools.DehumidifierSetMode
    ]

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{
      set_power: {"dehumidifier.set_power", Dobby.DeviceAgents.Dehumidifier.SetPower},
      set_humidity: {"dehumidifier.set_humidity", Dobby.DeviceAgents.Dehumidifier.SetHumidity},
      set_mode: {"dehumidifier.set_mode", Dobby.DeviceAgents.Dehumidifier.SetMode}
    }
end
