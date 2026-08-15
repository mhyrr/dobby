defmodule DobbyWeb.Flap do
  @moduledoc """
  The board's vocabulary (surface design §1.1).

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
  attr :state, :atom,
    required: true,
    values: [:set, :acting, :refused, :silent, :expected]

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def flap(assigns) do
    ~H"""
    <span class={["flap", @class]} data-st={@state}>{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  A rule in brass, the board's only divider.
  """
  attr :class, :string, default: nil

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
  def read(%{type: :thermostat} = snapshot) do
    cond do
      not snapshot.available -> %{word: "Quiet", state: :silent, value: temperature(snapshot)}
      is_nil(snapshot.target_temperature_f) -> unknown(temperature(snapshot))
      warming?(snapshot) -> %{word: "Warming", state: :acting, value: temperature(snapshot)}
      cooling?(snapshot) -> %{word: "Cooling", state: :acting, value: temperature(snapshot)}
      true -> %{word: "Set", state: :set, value: temperature(snapshot)}
    end
  end

  def read(%{type: :wifi_endpoint} = snapshot) do
    case {snapshot.available, snapshot.online} do
      {true, true} -> %{word: "Awake", state: :acting, value: nil}
      {true, false} -> %{word: "Quiet", state: :silent, value: nil}
      _unknown -> unknown(nil)
    end
  end

  def read(%{available: true}), do: %{word: "Awake", state: :acting, value: nil}
  def read(_snapshot), do: unknown(nil)

  defp unknown(value), do: %{word: "Not known", state: :silent, value: value}

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
