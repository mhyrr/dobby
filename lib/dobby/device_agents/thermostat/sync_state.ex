defmodule Dobby.DeviceAgents.Thermostat.SyncState do
  @moduledoc """
  Translates an inbound HA `state_changed` into thermostat agent state.

  This is the only way thermostat readings ever change. A command Dobby issues
  does not update this agent — the command goes to HA, HA moves the world, and
  the world comes back through here. That round trip is why the system prompt
  can tell the model to report what it commanded rather than claim it observed
  the result.

  Capability discovery (design §4.3) rides along: `min_temp`, `max_temp`, and
  the step arrive as ordinary attributes, and they are the device's real
  envelope.
  """

  use Jido.Action,
    name: "thermostat_sync_state",
    description: "Applies a Home Assistant state change to thermostat agent state",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      attributes: [type: :map, default: %{}]
    ]

  alias Dobby.DeviceAgent
  alias Dobby.DeviceAgents.Thermostat
  alias Dobby.DeviceEvents

  @watched [:available, :hvac_mode, :current_temperature_f, :target_temperature_f]

  # HA reports temperatures in the unit system the instance is configured for.
  # Dobby's field names say Fahrenheit and the rig speaks Fahrenheit; whether
  # the real house does is a Phase B inventory question, not something to
  # paper over with a guess at a conversion here.
  @impl true
  def run(params, context) do
    previous = context.state
    attributes = params.attributes

    next = %{
      available: params.state not in [nil, "unavailable", "unknown"],
      hvac_mode: parse_mode(params.state),
      current_temperature_f: attribute(attributes, [:current_temperature, "current_temperature"]),
      target_temperature_f: attribute(attributes, [:temperature, "temperature"]),
      capabilities: discover_capabilities(previous.capabilities, attributes)
    }

    case DeviceAgent.changes(previous, next, @watched) do
      %{changed: []} ->
        {:ok, next}

      %{changed: changed, moved: moved} ->
        {:ok, next,
         [
           DeviceEvents.emit(previous.dobby_id, snapshot(previous, next),
             changed: changed,
             moved: moved,
             commanded?: commanded?(previous, next)
           )
         ]}
    end
  end

  @doc """
  Whether this setpoint is the echo of a command this house issued.

  Every path that moves a setpoint — the model's tool, a card someone tapped, a
  schedule at eight o'clock — goes through `SetTemperature` and lands in
  `last_command`, and all three announce themselves in the thread at the moment
  they act. What comes back through Home Assistant afterwards is the same event
  a second time, and saying it twice would make the thread read as though
  somebody had gone and turned the dial by hand.

  So the setpoint we asked for and got is ours, and any other setpoint is
  somebody's hand. The one case this rounds off is a person setting the dial
  back to a value Dobby had already commanded, which reads as ours and is not
  worth a timestamp to catch.
  """
  @spec commanded?(map(), map()) :: boolean()
  def commanded?(previous, next) do
    case Map.get(previous, :last_command) do
      %{result: :accepted, temperature_f: temperature} ->
        temperature == next.target_temperature_f

      _never_or_refused ->
        false
    end
  end

  @doc """
  The device's public state, read from live agent state.

  `Dobby.DeviceAgent.snapshot/1` for this device type: a surface that has just
  opened needs the house as it is now, and state-change events only describe
  changes.
  """
  @spec snapshot(map()) :: map()
  def snapshot(state), do: snapshot(state, state)

  @doc """
  The device's public state — what cards render and the model is told.
  """
  @spec snapshot(map(), map()) :: map()
  def snapshot(previous, next) do
    # The range travels with the snapshot because the card is the one surface
    # that offers a setpoint before anybody names one, and a control that lets
    # you reach 85° in a house capped at 76 is a control that exists to be
    # refused. `accepted_range/1` reads capabilities from `next` and household
    # policy from `previous`, so it is asked of the two merged.
    {min, max} = Thermostat.accepted_range(Map.merge(previous, next))

    %{
      id: previous.dobby_id,
      name: previous.name,
      type: :thermostat,
      available: next.available,
      current_temperature_f: next.current_temperature_f,
      target_temperature_f: next.target_temperature_f,
      hvac_mode: next.hvac_mode,
      min_temperature_f: min,
      max_temperature_f: max
    }
  end

  # Capability discovery is additive: an event that omits the envelope
  # attributes must not erase what a previous event taught us.
  defp discover_capabilities(previous, attributes) do
    [
      {:min_temperature_f, [:min_temp, "min_temp"]},
      {:max_temperature_f, [:max_temp, "max_temp"]},
      {:step_f, [:target_temp_step, "target_temp_step"]},
      {:hvac_modes, [:hvac_modes, "hvac_modes"]}
    ]
    |> Enum.reduce(previous || %{}, fn {key, aliases}, acc ->
      case attribute(attributes, aliases) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # HA's climate hvac_mode vocabulary is closed. Anything outside it is a
  # genuine surprise, and reads better as "we don't know" than as an atom
  # conjured from whatever the integration happened to send.
  @hvac_modes %{
    "off" => :off,
    "heat" => :heat,
    "cool" => :cool,
    "heat_cool" => :heat_cool,
    "auto" => :auto,
    "dry" => :dry,
    "fan_only" => :fan_only
  }

  defp parse_mode(state), do: Map.get(@hvac_modes, state)

  defp attribute(attributes, keys) do
    Enum.find_value(keys, fn key -> Map.get(attributes, key) end)
  end
end
