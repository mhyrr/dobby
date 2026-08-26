defmodule Dobby.DeviceAgents.Light.SetBrightness do
  @moduledoc """
  Decides whether a brightness is allowed, and if so describes the HA call.

  The decision leans on discovery (design §4.3): a bulb that never reported
  a color mode beyond `onoff` is refused with the reason, not commanded
  blind. The call itself is `light.turn_on` with `brightness_pct` — in HA,
  setting brightness on an off light turns it on at that level, and that is
  the semantic Dobby inherits rather than reinvents.
  """

  use Jido.Action,
    name: "light_set_brightness",
    description: "Validates a light brightness and emits the Home Assistant call",
    schema: [
      brightness_percent: [
        type: :integer,
        required: true,
        doc: "How bright to make the light, from 0 to 100."
      ],
      ref: [type: :string, required: true]
    ]

  alias Dobby.DeviceAgents.Light
  alias Dobby.Directive.HACall

  @impl true
  def run(%{brightness_percent: percent, ref: ref}, context) do
    state = context.state

    case authorize(state, percent) do
      :ok ->
        {:ok, %{last_command: accepted(ref, percent)},
         [
           %HACall{
             domain: "light",
             service: "turn_on",
             entity_id: state.entity_id,
             data: %{brightness_pct: percent}
           }
         ]}

      {:error, reason} ->
        {:ok, %{last_command: rejected(ref, reason)}}
    end
  end

  defp authorize(state, percent) do
    cond do
      state.available != true ->
        {:error, "#{state.name} is unavailable"}

      not Light.dimmable?(state) ->
        {:error, "#{state.name} does not support brightness; it can only be on or off"}

      percent < 1 or percent > 100 ->
        {:error, "brightness must be between 1 and 100 percent; to darken the room, turn it off"}

      true ->
        :ok
    end
  end

  defp accepted(ref, percent) do
    %{ref: ref, action: :set_brightness, result: :accepted, brightness_percent: percent}
  end

  defp rejected(ref, reason) do
    %{ref: ref, action: :set_brightness, result: {:rejected, reason}}
  end
end
