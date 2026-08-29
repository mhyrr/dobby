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

  ## Palette law

  Five reserved colors, each meaning exactly one thing, used decoratively
  nowhere. State color lives on ink, rules and flap edges — never as a tint
  behind readable text, which is also what keeps a screen left on in a kitchen
  from lighting the room at 11pm.
  """

  use Phoenix.Component

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
    do: observed(snapshot, primary_reading(snapshot))

  def read(%{type: :contact_sensor} = snapshot),
    do: observed(snapshot, boolean_value(snapshot.open, "Open", "Closed"))

  def read(%{type: :occupancy_sensor} = snapshot),
    do: observed(snapshot, boolean_value(snapshot.occupied, "Occupied", "Clear"))

  def read(%{type: :safety_sensor} = snapshot),
    do: observed(snapshot, boolean_value(snapshot.alarm, "Alarm", "Clear"))

  def read(%{available: true}), do: %{word: "Awake", state: :acting, value: nil}
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

  defp percent_or_state(percent, _state) when is_number(percent), do: "#{percent}%"
  defp percent_or_state(_percent, state), do: atom_value(state)

  defp atom_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp atom_value(_value), do: nil

  defp boolean_value(true, yes, _no), do: yes
  defp boolean_value(false, _yes, no), do: no
  defp boolean_value(nil, _yes, _no), do: nil

  defp primary_reading(%{readings: readings, units: units}) do
    [:temperature, :humidity, :carbon_dioxide, :air_quality, :pm25]
    |> Enum.find_value(fn key ->
      case Map.get(readings, key) do
        value when is_number(value) -> "#{value}#{Map.get(units, key, "")}"
        _missing -> nil
      end
    end)
  end

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
