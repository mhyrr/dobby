defmodule DobbyWeb.Flap do
  @moduledoc """
  The board's vocabulary (`DESIGN.md` — The State Vocabulary).

  A split-flap board can only display what it was set to. It cannot show a
  state nobody commanded — which is §6.2's write-acknowledgment rule as a
  mechanism rather than a prompt instruction, and it is the whole reason this
  is the surface Dobby got.

  **States are words, never icons and never bare numbers.** A number tells you
  what the thermostat reads; the word next to it tells you whether anybody
  asked for that.

  | Word | Means |
  |---|---|
  | `SET` | a commanded value — not "the room is warm" |
  | `WARMING` / `COOLING` | the device is acting on it |
  | `READY` | a schedule waiting for its time |
  | `AWAKE` | an endpoint that answers |
  | `LISTENING` | Dobby is attending |
  | `QUIET` | an endpoint that has stopped answering |
  | `HELD` | the device declined, with the reason beside it |
  | `NOT KNOWN` | nobody has told us yet |

  `NOT KNOWN` is the one word added while building this. `wifi_get_status`
  already insists that unknown "is not the same as offline", and the board was
  about to say `QUIET` for both — which is the surface quietly contradicting
  the tool. A house that has just booted knows nothing about its devices for a
  second or two, and saying so is more honest than guessing.

  ## The appliances

  Fifteen types arrived at once, and they split on one question: can the house
  write the thing this row is showing? Ten only read, so they take `AWAKE` the
  way the sensors do — the endpoint answers, and the reading beside the word is
  what it answered. Five can be commanded, so they take `SET`, the same word
  the switch and the fan take.

  **A read-only appliance never fills its column with a stored target.** Its
  word is `AWAKE`, and a setpoint printed beside that word reads as what the
  appliance *is* — exactly the confusion `Dobby.DeviceAgents.Refrigerator`
  names in its own moduledoc when it says a setpoint must never stand in for a
  missing measurement. A target belongs in this column only where the word
  beside it is `SET`, which is why a water heater shows the temperature
  somebody asked for and a refrigerator shows what its compartment reads.

  ## Palette law

  Five reserved colors, each meaning exactly one thing, used decoratively
  nowhere. State color lives on ink, rules and flap edges — never as a tint
  behind readable text, which is also what keeps a screen left on in a kitchen
  from lighting the room at 11pm.
  """

  use Phoenix.Component

  # Every cycle appliance's last resort, and it says what a contact sensor
  # says, because it is one.
  @door {:door_open, {"Open", "Closed"}}

  @doc """
  One flap card.

  The fold is drawn by CSS, behind the lettering and never across it: a seam
  over the glyphs reads as a strikethrough, and a struck word means cancelled,
  which would be a lie about every state on this board.
  """
  attr(:state, :atom,
    required: true,
    values: [:set, :acting, :refused, :silent, :expected]
  )

  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def flap(assigns) do
    ~H"""
    <span class={["flap", @class]} data-st={@state}>{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  A rule in brass, the board's only divider.
  """
  attr(:class, :string, default: nil)

  def rule(assigns) do
    ~H"""
    <hr class={["board-rule", @class]} />
    """
  end

  @doc """
  What a device snapshot says, as a word, a color, and a reading.

  Keyed on `snapshot.type` because the reading is per-device knowledge: a
  thermostat's word depends on whether it is closing a gap, and an endpoint's
  on whether it answers. A device type that reaches here without a clause gets
  availability alone, which is true of anything.

  The word is never inferred from the number alone. `SET` says a value was
  commanded; `WARMING` says Home Assistant reported the device acting on it.
  Dobby claiming the room is warm is exactly what doctrine forbids, and the
  board must not say it on his behalf.
  """
  @spec read(map()) :: %{word: String.t(), state: atom(), value: String.t() | nil}
  def read(%{command_status: :not_known} = snapshot) do
    current = snapshot |> Map.delete(:command_status) |> read()
    %{current | word: "Not known", state: :silent}
  end

  def read(%{type: :thermostat} = snapshot) do
    cond do
      # `nil` before `false`, and they are different rows on purpose: a device
      # that has not reported is NOT KNOWN, and one that has stopped answering
      # is QUIET. Rounding the first into the second is the surface
      # contradicting `wifi_get_status`, which insists to the model that they
      # are not the same.
      is_nil(snapshot.available) -> unknown(temperature(snapshot))
      not snapshot.available -> %{word: "Quiet", state: :silent, value: temperature(snapshot)}
      is_nil(snapshot.target_temperature_f) -> unknown(temperature(snapshot))
      warming?(snapshot) -> %{word: "Warming", state: :acting, value: temperature(snapshot)}
      cooling?(snapshot) -> %{word: "Cooling", state: :acting, value: temperature(snapshot)}
      true -> %{word: "Set", state: :set, value: temperature(snapshot)}
    end
  end

  def read(%{type: :light} = snapshot) do
    cond do
      # `nil` before `false`, for the thermostat's reason: not reported yet
      # is NOT KNOWN, stopped answering is QUIET.
      is_nil(snapshot.available) -> unknown(light_value(snapshot))
      not snapshot.available -> %{word: "Quiet", state: :silent, value: light_value(snapshot)}
      is_nil(snapshot.power) -> unknown(nil)
      true -> %{word: "Set", state: :set, value: light_value(snapshot)}
    end
  end

  # In motion — cleaning, returning — is a commanded state, so it reads SET;
  # a robot sitting home and answering reads AWAKE; error reads HELD, the
  # nearest word this vocabulary has for "the device is refusing". If a
  # vacuum earns its own word (WORKING?), that is a DESIGN.md decision, not
  # a clause here.
  def read(%{type: :vacuum} = snapshot) do
    cond do
      # `nil` before `false`, for the thermostat's reason: not reported yet
      # is NOT KNOWN, stopped answering is QUIET.
      is_nil(snapshot.available) ->
        unknown(battery(snapshot))

      not snapshot.available ->
        %{word: "Quiet", state: :silent, value: battery(snapshot)}

      is_nil(snapshot.activity) ->
        unknown(battery(snapshot))

      snapshot.activity in [:cleaning, :returning] ->
        %{word: "Set", state: :set, value: battery(snapshot)}

      snapshot.activity == :error ->
        %{word: "Held", state: :refused, value: battery(snapshot)}

      true ->
        %{word: "Awake", state: :acting, value: battery(snapshot)}
    end
  end

  def read(%{type: :wifi_endpoint} = snapshot) do
    case {snapshot.available, snapshot.online} do
      {true, true} -> %{word: "Awake", state: :acting, value: nil}
      {true, false} -> %{word: "Quiet", state: :silent, value: nil}
      _unknown -> unknown(nil)
    end
  end

  def read(%{type: :speaker} = snapshot),
    do: observed(snapshot, speaker_value(snapshot))

  def read(%{type: :camera} = snapshot),
    do: observed(snapshot, if(snapshot.motion, do: "Motion", else: atom_value(snapshot.activity)))

  def read(%{type: :doorbell} = snapshot),
    do: observed(snapshot, snapshot.last_event)

  def read(%{type: :lock} = snapshot),
    do: observed(snapshot, atom_value(snapshot.lock_state))

  def read(%{type: :access_cover} = snapshot),
    do: observed(snapshot, atom_value(snapshot.cover_state))

  def read(%{type: :power_switch} = snapshot),
    do: commanded(snapshot, atom_value(snapshot.power))

  def read(%{type: :shade} = snapshot),
    do: commanded(snapshot, percent_or_state(snapshot.position, snapshot.shade_state))

  def read(%{type: :fan} = snapshot),
    do: commanded(snapshot, percent_or_state(snapshot.speed_percent, snapshot.power))

  def read(%{type: :environment_monitor} = snapshot),
    do:
      observed(
        snapshot,
        reading(snapshot, [:temperature, :humidity, :carbon_dioxide, :air_quality, :pm25])
      )

  def read(%{type: :contact_sensor} = snapshot),
    do: observed(snapshot, boolean_value(snapshot.open, "Open", "Closed"))

  def read(%{type: :occupancy_sensor} = snapshot),
    do: observed(snapshot, boolean_value(snapshot.occupied, "Occupied", "Clear"))

  def read(%{type: :safety_sensor} = snapshot),
    do: observed(snapshot, boolean_value(snapshot.alarm, "Alarm", "Clear"))

  # ── the appliances that only read ──────────────────────────────────────────
  #
  # AWAKE, the same word the sensors above take, because that is all these
  # types can honestly say: the endpoint answers, and this is what it answered.
  # Not a word of their own — a cycle appliance mid-programme is doing
  # something, and WORKING would be a ninth word, which is a DESIGN.md decision
  # rather than a clause here.

  def read(%{type: :dishwasher} = snapshot),
    do: observed(snapshot, reading(snapshot, [:operation_state, :program, :progress, @door]))

  def read(%{type: :oven} = snapshot),
    do:
      observed(
        snapshot,
        reading(snapshot, [:temperature, :operation_state, :probe_temperature, @door])
      )

  def read(%{type: :refrigerator} = snapshot),
    do:
      observed(
        snapshot,
        reading(snapshot, [
          :refrigerator_display_temperature,
          :freezer_display_temperature,
          {:refrigerator_door_open, {"Open", "Closed"}},
          {:freezer_door_open, {"Open", "Closed"}}
        ])
      )

  # One row, twice: a washer and a dryer report the same laundry cycle and the
  # board has no reason to draw them differently.
  def read(%{type: type} = snapshot) when type in [:washer, :dryer],
    do:
      observed(
        snapshot,
        reading(snapshot, [:operation_state, :program, :progress, :remaining_time, @door])
      )

  def read(%{type: :coffee_maker} = snapshot),
    do: observed(snapshot, reading(snapshot, [:operation_state, :program]))

  def read(%{type: :wine_cooler} = snapshot),
    do:
      observed(
        snapshot,
        reading(snapshot, [:temperature, :upper_temperature, :lower_temperature, @door])
      )

  def read(%{type: :ice_maker} = snapshot),
    do: observed(snapshot, reading(snapshot, [:operation_state]))

  def read(%{type: :cooktop} = snapshot),
    do:
      observed(
        snapshot,
        reading(snapshot, [
          :operation_state,
          :power_level,
          {:active, {"Running", "Idle"}},
          {:hot_surface, {"Hot", "Cool"}}
        ])
      )

  def read(%{type: :microwave} = snapshot),
    do: observed(snapshot, reading(snapshot, [:operation_state, :remaining_time, @door]))

  # ── the appliances that can be written ─────────────────────────────────────
  #
  # SET, the same word the switch, the shade and the fan take, and for the same
  # reason: every value shown here is one somebody asked for. A water heater
  # that has just been told 120° says SET and not AWAKE — reading it as an
  # endpoint that answers would invert the Commanded-Not-Observed Rule on the
  # one row in this group where the number matters most.

  def read(%{type: :water_heater} = snapshot),
    do: commanded(snapshot, water_value(snapshot))

  def read(%{type: type} = snapshot) when type in [:humidifier, :dehumidifier],
    do: commanded(snapshot, percent_or_state(snapshot.target_humidity_percent, snapshot.power))

  def read(%{type: type} = snapshot) when type in [:air_purifier, :range_hood],
    do: commanded(snapshot, percent_or_state(snapshot.speed_percent, snapshot.power))

  # A type with no clause of its own gets availability alone, which is true of
  # anything — but it gets it through the three-way helper every type uses. The
  # old fallback said AWAKE for a device that answers and NOT KNOWN for
  # everything else, which folded "stopped answering" into "nobody has told us
  # yet": the one distinction this vocabulary was extended to keep. A
  # registered type reaching here is a bug rather than a default, and this is
  # what the board says while somebody fixes it.
  def read(%{available: available} = snapshot) when available in [true, false, nil],
    do: observed(snapshot, nil)

  def read(_snapshot), do: unknown(nil)

  defp unknown(value), do: %{word: "Not known", state: :silent, value: value}

  defp observed(%{available: nil}, value), do: unknown(value)
  defp observed(%{available: false}, value), do: %{word: "Quiet", state: :silent, value: value}
  defp observed(%{available: true}, value), do: %{word: "Awake", state: :acting, value: value}

  defp commanded(%{available: nil}, value), do: unknown(value)
  defp commanded(%{available: false}, value), do: %{word: "Quiet", state: :silent, value: value}
  defp commanded(%{available: true}, value), do: %{word: "Set", state: :set, value: value}

  defp speaker_value(%{media_title: title}) when is_binary(title) and title != "", do: title
  defp speaker_value(%{volume_percent: percent}) when is_number(percent), do: "#{percent}%"
  defp speaker_value(%{playback: playback}), do: atom_value(playback)

  defp percent_or_state(percent, _state) when is_number(percent),
    do: number_value(percent) <> "%"

  defp percent_or_state(_percent, state), do: atom_value(state)

  # `nil` is an atom, so without this clause an attribute nobody has reported
  # yet reads "Nil" on the board — a word that is in no vocabulary at all.
  defp atom_value(nil), do: nil

  defp atom_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp atom_value(_value), do: nil

  defp boolean_value(true, yes, _no), do: yes
  defp boolean_value(false, _yes, no), do: no
  defp boolean_value(nil, _yes, _no), do: nil

  # The first of an ordered list of readings that is actually known. A bare key
  # is a scalar and prints itself with its unit; a `{key, {yes, no}}` pair is a
  # boolean and names both of its faces, the way a contact sensor does.
  #
  # A list stops at the last reading that can be said in the board's plain
  # register. Where a boolean has no plain word for both faces — an ice bin
  # that is not full is not the same as one that is empty, and the ice maker
  # says so itself — the list ends there and the column stays blank. That is
  # The Absent Word Rule, carried from the flap to the reading beside it: a
  # phrase invented to fill a column is worse than a column with nothing in it.
  @doc """
  The first reading an appliance carries out of `candidates`, with its unit.

  A candidate is a reading key, or `{key, {yes, no}}` for a boolean read as
  one of two words. Public because the card's detail line wants an
  appliance's *other* number by the same rendering the row uses for its
  first — the target under an oven's temperature — and two renderings of one
  reading would drift.
  """
  @spec reading(map(), [atom() | {atom(), {String.t(), String.t()}}]) :: String.t() | nil
  def reading(%{readings: readings, units: units}, candidates) do
    Enum.find_value(candidates, fn
      {key, {yes, no}} -> boolean_value(Map.get(readings, key), yes, no)
      key -> scalar_value(Map.get(readings, key), Map.get(units, key))
    end)
  end

  defp scalar_value(value, unit) when is_number(value),
    do: number_value(value) <> unit_suffix(unit)

  defp scalar_value(value, _unit) when is_binary(value) and value != "", do: text_value(value)
  defp scalar_value(_value, _unit), do: nil

  # Home Assistant sends every scalar over the wire as a string, and an
  # integration that writes "38.0" for a whole temperature parses to a float
  # however carefully the readings layer keeps whole numbers whole. The board
  # writes the number, not the parse.
  defp number_value(value) when is_integer(value), do: Integer.to_string(value)

  defp number_value(value) when is_float(value) do
    if value == trunc(value),
      do: Integer.to_string(trunc(value)),
      else: Float.to_string(value)
  end

  # A degree sign and a percent belong to the number. Anything else is a word,
  # and a word takes the space a word takes.
  defp unit_suffix(unit) when unit in ["%", "°", "°F", "°C"], do: unit
  defp unit_suffix(unit) when is_binary(unit) and unit != "", do: " " <> unit
  defp unit_suffix(_unit), do: ""

  # An appliance's own word for what it is doing. Underscores become spaces, and
  # the first letter is raised if it needs raising — but the rest is left alone.
  # `ApplianceReadings` keeps the integration's casing on purpose, because the
  # cycle word is the only description of the cycle anybody has; capitalising the
  # whole string turned "DelayedStart" into "Delayedstart" and threw that away.
  defp text_value(value) do
    case String.replace(value, "_", " ") do
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
      empty -> empty
    end
  end

  # Every value a water heater shows is one somebody asked for — the target,
  # the mode, the switch. The tank's own temperature is an observation and has
  # no business on a row whose word is SET.
  defp water_value(%{target_temperature_f: target}) when is_number(target),
    do: "#{round(target)}°"

  defp water_value(%{mode: mode}) when is_binary(mode) and mode != "", do: text_value(mode)
  defp water_value(%{power: power}), do: atom_value(power)

  # On or off is the reading; a dimmed light's percentage is the more exact
  # form of "on". Either way the word is SET — it is a commanded state, which
  # is the only thing this board is allowed to say.
  defp light_value(%{power: :on, brightness_percent: percent}) when is_number(percent),
    do: "#{percent}%"

  defp light_value(%{power: :on}), do: "On"
  defp light_value(%{power: :off}), do: "Off"
  defp light_value(_snapshot), do: nil

  defp battery(%{battery_percent: percent}) when is_number(percent), do: "#{percent}%"
  defp battery(_snapshot), do: nil

  # Half a degree of slack: a thermostat sitting exactly on its setpoint
  # wobbles, and a board that flips between SET and WARMING every few minutes
  # is describing the sensor rather than the house.
  defp warming?(%{hvac_mode: :cool}), do: false

  defp warming?(%{current_temperature_f: current, target_temperature_f: target})
       when is_number(current) and is_number(target),
       do: current < target - 0.5

  defp warming?(_snapshot), do: false

  defp cooling?(%{hvac_mode: :heat}), do: false

  defp cooling?(%{current_temperature_f: current, target_temperature_f: target})
       when is_number(current) and is_number(target),
       do: current > target + 0.5

  defp cooling?(_snapshot), do: false

  defp temperature(%{target_temperature_f: target}) when is_number(target),
    do: "#{round(target)}°"

  defp temperature(%{current_temperature_f: current}) when is_number(current),
    do: "#{round(current)}°"

  defp temperature(_snapshot), do: nil
end
