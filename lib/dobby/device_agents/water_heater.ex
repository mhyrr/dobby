defmodule Dobby.DeviceAgents.WaterHeater do
  @moduledoc """
  The household's hot-water supply, governed by HA's water_heater contract.

  Every control requires an advertised feature. Temperatures are presented in
  Fahrenheit, but service calls use HA's configured temperature unit. Standard
  HA water heaters omit unit_of_measurement, so the household must declare
  `temperature_unit` to match HA's system setting when the entity omits it.
  An explicit entity unit wins; missing or invalid units never become a guess.

  Household bounds only narrow the reported hardware range. Commands change
  last_command alone: warm water is an observation that only HA can report.
  """

  use Jido.Agent,
    name: "water_heater",
    description: "Reports and controls the household water heater",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.WaterHeater.SyncState},
      {"water_heater.set_temperature", Dobby.DeviceAgents.WaterHeater.SetTemperature},
      {"water_heater.set_mode", Dobby.DeviceAgents.WaterHeater.SetMode},
      {"water_heater.set_away_mode", Dobby.DeviceAgents.WaterHeater.SetAwayMode},
      {"water_heater.set_power", Dobby.DeviceAgents.WaterHeater.SetPower}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      power: [type: {:or, [:atom, nil]}, default: nil],
      mode: [type: {:or, [:string, nil]}, default: nil],
      away_mode: [type: {:or, [:boolean, nil]}, default: nil],
      temperature_unit: [type: {:or, [:string, nil]}, default: nil],
      current_temperature: [type: {:or, [:integer, :float, nil]}, default: nil],
      target_temperature: [type: {:or, [:integer, :float, nil]}, default: nil],
      current_temperature_f: [type: {:or, [:integer, :float, nil]}, default: nil],
      target_temperature_f: [type: {:or, [:integer, :float, nil]}, default: nil],
      capabilities: [type: {:or, [:map, nil]}, default: nil],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent
  alias Dobby.Home.Device

  @impl Dobby.DeviceAgent
  def config_type, do: "water_heater"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Dobby.HomeAssistant.Entity.domain(entity) == "water_heater"

  @impl Dobby.DeviceAgent
  def config_schema do
    [
      temperature_unit: [
        type: {:in, ["°F", "°C", "K"]},
        doc:
          "Match HA's system temperature unit. Required for temperature control when HA omits the entity unit."
      ],
      min_temperature_f: [
        type: {:or, [:integer, :float]},
        doc: "Household minimum target in Fahrenheit; narrows HA's range."
      ],
      max_temperature_f: [
        type: {:or, [:integer, :float]},
        doc: "Household maximum target in Fahrenheit; narrows HA's range."
      ]
    ]
  end

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device) do
    with :ok <- Dobby.DeviceAgents.Validation.device(device, [:water_heater]),
         true <- Regex.match?(~r/^water_heater\.[a-z0-9_]+$/, device.bindings.water_heater),
         {:ok, _} <- NimbleOptions.validate(Map.to_list(device.settings), config_schema()) do
      min = device.settings[:min_temperature_f]
      max = device.settings[:max_temperature_f]

      if is_number(min) and is_number(max) and min > max,
        do: {:error, "min_temperature_f exceeds max_temperature_f"},
        else: :ok
    else
      false -> {:error, "bindings.water_heater must name a water_heater entity"}
      {:error, %NimbleOptions.ValidationError{} = reason} -> {:error, Exception.message(reason)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Dobby.DeviceAgent
  def tools,
    do: [
      Dobby.Tools.WaterHeaterGetStatus,
      Dobby.Tools.WaterHeaterSetTemperature,
      Dobby.Tools.WaterHeaterSetMode,
      Dobby.Tools.WaterHeaterSetAwayMode,
      Dobby.Tools.WaterHeaterTurnOn,
      Dobby.Tools.WaterHeaterTurnOff
    ]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:water_heater]

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{
      set_temperature: {"water_heater.set_temperature", __MODULE__.SetTemperature},
      set_mode: {"water_heater.set_mode", __MODULE__.SetMode},
      set_away_mode: {"water_heater.set_away_mode", __MODULE__.SetAwayMode},
      set_power: {"water_heater.set_power", __MODULE__.SetPower}
    }

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: __MODULE__.SyncState

  # The setpoint fader, between the ends the snapshot already carries — the
  # accepted range, which is the hardware's narrowed by the household's. Only
  # once the heater has reported a target and a range; a heater whose
  # integration reports no temperature support gets no fader rather than one
  # that exists to be refused.
  @impl Dobby.DeviceAgent
  def controls(%{available: true} = snapshot) do
    Enum.reject([temperature_fader(snapshot)], &is_nil/1)
  end

  def controls(_snapshot), do: []

  defp temperature_fader(%{
         capabilities: %{supports_temperature: true},
         target_temperature_f: target,
         min_temperature_f: min,
         max_temperature_f: max
       })
       when is_number(target) and is_number(min) and is_number(max) and min < max do
    %{
      kind: :fader,
      action: :set_temperature,
      arg: :temperature_f,
      field: :target_temperature_f,
      min: min,
      max: max,
      step: 1,
      unit: "°"
    }
  end

  defp temperature_fader(_snapshot), do: nil

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device),
    do: Dobby.DeviceAgent.initial_state(device, :water_heater)

  @impl Dobby.DeviceAgent
  def intervention?(attribute),
    do: attribute in [:target_temperature_f, :mode, :away_mode, :power]

  @impl Dobby.DeviceAgent
  def command_arrived?(
        %{result: :accepted, action: :set_temperature, temperature_f: expected},
        %{available: true, target_temperature_f: reported} = snapshot
      )
      when is_number(expected) and is_number(reported),
      do: abs(expected - reported) <= arrival_tolerance_f(snapshot[:temperature_unit])

  def command_arrived?(
        %{result: :accepted, action: :set_mode, mode: expected},
        %{available: true, mode: reported}
      )
      when is_binary(expected), do: expected == reported

  def command_arrived?(
        %{result: :accepted, action: :set_away_mode, away_mode: expected},
        %{available: true, away_mode: reported}
      )
      when is_boolean(expected), do: expected == reported

  def command_arrived?(
        %{result: :accepted, action: :set_power, power: expected},
        %{available: true, power: reported}
      )
      when expected in [:on, :off], do: expected == reported

  def command_arrived?(_, _), do: false

  # Home Assistant does not echo the number Dobby sent; it echoes that number at
  # the entity's reporting precision, which `WaterHeaterEntity.precision` fixes
  # from the system unit — tenths on a Celsius house, whole degrees on a
  # Fahrenheit one. A Fahrenheit target crossing that rounding comes back
  # changed: 120°F is 48.888…°C on the wire, HA reports 48.9, and Dobby reads
  # 120.02 back. Comparing at float precision called that a command that never
  # arrived, which on a Celsius house was true of 41 of the 46 targets between
  # 100 and 145°F — and the cost was two false lines, a NOT KNOWN plus a
  # thread line crediting a person with Dobby's own command.
  #
  # Half a reporting step is the most the wire can differ from what was asked
  # for, so that is the tolerance. It stays far below a real disagreement: the
  # smallest difference a Celsius house can express is 0.1°C, or 0.18°F, so a
  # value somebody actually changed can never pass as ours.
  defp arrival_tolerance_f("°F"), do: 0.5
  defp arrival_tolerance_f(_tenths_of_a_degree), do: 0.1

  @doc false
  def to_f(value, "°F") when is_number(value), do: value
  def to_f(value, "°C") when is_number(value), do: value * 9 / 5 + 32
  def to_f(value, "K") when is_number(value), do: (value - 273.15) * 9 / 5 + 32
  def to_f(_, _), do: nil

  @doc false
  def from_f(value, "°F"), do: value
  def from_f(value, "°C"), do: (value - 32) * 5 / 9
  def from_f(value, "K"), do: (value - 32) * 5 / 9 + 273.15

  @doc false
  def accepted_range(state) do
    capabilities = state.capabilities || %{}
    min = capabilities[:min_temperature_f]
    max = capabilities[:max_temperature_f]

    if is_number(min) and is_number(max) and min <= max do
      {max(min, state.settings[:min_temperature_f] || min),
       min(max, state.settings[:max_temperature_f] || max)}
    else
      {nil, nil}
    end
  end
end
