defmodule Dobby.DeviceAgents.Humidity do
  @moduledoc """
  HA's humidity contract shared by two opposite household jobs.

  Both semantic types speak `humidifier.*`; the reported device class keeps
  drying from being mistaken for adding moisture. Power and humidity are core
  HA services. Only mode selection has a feature bit. A known range is required
  before setting humidity, and household bounds can only narrow that range.
  Unavailable reports erase readings and capabilities, including stale echoes.
  """

  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents
  alias Dobby.Directive.HACall
  alias Dobby.HomeAssistant.Entity

  @fields [
    :available,
    :device_class,
    :power,
    :current_humidity_percent,
    :target_humidity_percent,
    :action,
    :mode,
    :capabilities
  ]

  def matches_entity?(entity, type),
    do: Entity.domain(entity) == "humidifier" and entity.device_class == Atom.to_string(type)

  # What a standing rule may watch. `mode` is not here: HA advertises the mode
  # list per device in `available_modes`, so there is no closed set to name —
  # `set_mode/2` validates against whatever that device advertised, and a rule
  # promising to watch a word this humidifier may not have is a rule that
  # never fires. `action` is a closed set, the four words `action/1` accepts.
  def observables,
    do: %{
      power: {:enum, [:on, :off]},
      action: {:enum, [:humidifying, :drying, :idle, :off]},
      current_humidity_percent: :number,
      target_humidity_percent: :number
    }

  def config_schema do
    [
      min_humidity_percent: [type: :integer, doc: "Lowest permitted humidity target, in percent."],
      max_humidity_percent: [
        type: :integer,
        doc: "Highest permitted humidity target, in percent."
      ]
    ]
  end

  def validate_device(device) do
    with :ok <- Dobby.DeviceAgents.Validation.device(device, [:humidifier]) do
      min = Map.get(device.settings, :min_humidity_percent, 0)
      max = Map.get(device.settings, :max_humidity_percent, 100)

      cond do
        not Regex.match?(~r/^humidifier\.[a-z0-9_]+$/, device.bindings.humidifier) ->
          {:error, "bindings.humidifier must name a humidifier entity"}

        not is_integer(min) or not is_integer(max) or min < 0 or max > 100 or min > max ->
          {:error, "humidity settings must form a range from 0 to 100 percent"}

        Map.keys(device.settings) -- [:min_humidity_percent, :max_humidity_percent] != [] ->
          {:error, "unknown humidity setting"}

        true ->
          :ok
      end
    end
  end

  def initial_state(device, type),
    do: Map.put(DeviceAgent.initial_state(device, :humidifier), :device_type, type)

  def snapshot(state) do
    state
    |> Map.take(@fields)
    |> Map.merge(%{
      id: state.dobby_id,
      name: state.name,
      type: state.device_type,
      units: %{current_humidity_percent: "%", target_humidity_percent: "%"}
    })
  end

  def sync(%{entity_id: entity_id} = params, %{entity_id: entity_id} = previous) do
    available = params.state in ["on", "off"]
    attrs = if available, do: params.attributes, else: %{}

    next = %{
      available: available,
      device_class: text(attrs["device_class"]),
      power: power(params.state),
      current_humidity_percent: percent(attrs["current_humidity"]),
      target_humidity_percent: percent(attrs["humidity"]),
      action: action(attrs["action"]),
      mode: text(attrs["mode"]),
      capabilities: %{
        min_humidity_percent: percent(attrs["min_humidity"]),
        max_humidity_percent: percent(attrs["max_humidity"]),
        target_humidity_step: positive(attrs["target_humidity_step"]),
        supports_modes: supports_modes(attrs["supported_features"]),
        available_modes: modes(attrs["available_modes"])
      }
    }

    case DeviceAgent.changes(previous, next, @fields) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        commanded = commanded(previous.last_command, changed, next)

        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(Map.merge(previous, next)),
             changed: changed,
             moved: moved,
             commanded: commanded,
             commanded?: commanded != []
           )
         ]}
    end
  end

  def sync(_params, _previous), do: {:ok, %{}}

  # What this command accounts for in this report, so the watcher can judge
  # whatever is left on its own.
  #
  # Target and mode move together on real integrations, in both directions.
  # Xiaomi's humidifiers switch to Auto when asked for a humidity, and a generic
  # hygrostat swaps its target when asked for away mode. Claiming only the
  # attribute the command was named for told the household somebody had turned
  # the other one by hand. The first attribute is the one the command is for,
  # and it gates the rest, so a mode somebody changed on a device that left the
  # target alone is still a hand.
  defp commanded(command, changed, next) do
    case command_attributes(command) do
      [primary | _] = attributes ->
        if primary in changed and command_arrived?(command, next),
          do: Enum.filter(attributes, &(&1 in changed)),
          else: []

      [] ->
        []
    end
  end

  defp command_attributes(%{action: :set_power}), do: [:power]
  defp command_attributes(%{action: :set_humidity}), do: [:target_humidity_percent, :mode]
  defp command_attributes(%{action: :set_mode}), do: [:mode, :target_humidity_percent]
  defp command_attributes(_), do: []

  def set_power(%{power: power, ref: ref}, state) do
    with :ok <- ready(state),
         true <- power in [:on, :off] do
      accept(state, ref, :set_power, %{power: power}, "turn_#{power}", %{})
    else
      {:error, reason} -> reject(ref, :set_power, reason)
      false -> reject(ref, :set_power, "power must be on or off")
    end
  end

  def set_humidity(%{target_humidity_percent: target, ref: ref}, state) do
    with :ok <- ready(state),
         :ok <- humidity_allowed(target, state) do
      accept(state, ref, :set_humidity, %{target_humidity_percent: target}, "set_humidity", %{
        humidity: target
      })
    else
      {:error, reason} -> reject(ref, :set_humidity, reason)
    end
  end

  def set_mode(%{mode: mode, ref: ref}, state) do
    with :ok <- ready(state),
         true <- state.capabilities[:supports_modes] == true,
         modes when is_list(modes) <- state.capabilities[:available_modes],
         true <- mode in modes do
      accept(state, ref, :set_mode, %{mode: mode}, "set_mode", %{mode: mode})
    else
      {:error, reason} -> reject(ref, :set_mode, reason)
      _ -> reject(ref, :set_mode, "mode must be one Home Assistant advertises for this device")
    end
  end

  def command_arrived?(%{result: :accepted, action: :set_power, power: expected}, %{power: actual}),
      do: actual == expected

  def command_arrived?(
        %{result: :accepted, action: :set_humidity, target_humidity_percent: expected},
        %{target_humidity_percent: actual}
      ),
      do: actual == expected

  def command_arrived?(%{result: :accepted, action: :set_mode, mode: expected}, %{mode: actual}),
    do: actual == expected

  def command_arrived?(_command, _state), do: false

  # Parse the whole model value. Partial strings and fractional percentages
  # must not silently become a different command through rounding/truncation.
  def normalize_target(value) when is_float(value) do
    if value == trunc(value), do: trunc(value), else: value
  end

  def normalize_target(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> normalize_target(number)
      _ -> value
    end
  end

  def normalize_target(value), do: value

  defp ready(state) do
    cond do
      state.available != true ->
        {:error, "#{state.name} is unavailable"}

      state.device_class != Atom.to_string(state.device_type) ->
        {:error, "Home Assistant has not confirmed the #{state.device_type} device class"}

      true ->
        :ok
    end
  end

  defp humidity_allowed(target, state) do
    low = state.capabilities[:min_humidity_percent]
    high = state.capabilities[:max_humidity_percent]
    step = state.capabilities[:target_humidity_step]
    min = max(low || 0, Map.get(state.settings, :min_humidity_percent, 0))
    max = min(high || 100, Map.get(state.settings, :max_humidity_percent, 100))

    cond do
      not is_integer(target) ->
        {:error, "humidity target must be a whole percent"}

      not is_number(low) or not is_number(high) or low > high ->
        {:error, "Home Assistant has not reported a valid humidity range"}

      # Household bounds narrow HA's range and can miss it entirely, which left
      # the refusal naming a range that reads backwards — "between 60 and 50
      # percent". The command is refused either way; the reason has to be a
      # sentence somebody can act on. The water heater already says this.
      min > max ->
        {:error, "household humidity bounds fall outside the range #{state.name} reports"}

      target < min or target > max ->
        {:error, "humidity target must be between #{min} and #{max} percent"}

      is_number(step) and abs((target - low) / step - round((target - low) / step)) > 0.000001 ->
        {:error, "humidity target must follow the reported #{step} percent step from #{low}"}

      true ->
        :ok
    end
  end

  defp accept(state, ref, action, result, service, data),
    do:
      {:ok, %{last_command: Map.merge(result, %{ref: ref, action: action, result: :accepted})},
       [%HACall{domain: "humidifier", service: service, entity_id: state.entity_id, data: data}]}

  defp reject(ref, action, reason),
    do: {:ok, %{last_command: %{ref: ref, action: action, result: {:rejected, reason}}}}

  defp power("on"), do: :on
  defp power("off"), do: :off
  defp power(_), do: nil
  defp percent(v) when is_number(v) and v >= 0 and v <= 100, do: v
  defp percent(_), do: nil
  defp positive(v) when is_number(v) and v > 0, do: v
  defp positive(_), do: nil
  defp text(v) when is_binary(v) and v not in ["", "unknown", "unavailable"], do: v
  defp text(_), do: nil
  defp action(v) when v in ["humidifying", "drying", "idle", "off"], do: v
  defp action(_), do: nil
  defp supports_modes(v) when is_integer(v) and v >= 0, do: Bitwise.band(v, 1) == 1
  defp supports_modes(_), do: nil

  defp modes(v) when is_list(v) do
    if Enum.all?(v, &(is_binary(&1) and &1 != "")), do: Enum.uniq(v), else: nil
  end

  defp modes(_), do: nil
end
