defmodule Dobby.Tools.LightTurnOn do
  @moduledoc """
  Tool: turn a light on.

  Transport only (design §6.2): the decision belongs to the light agent, and
  what comes back is *acceptance*, not observation — whether the room lit up
  arrives later as a state change from Home Assistant.
  """

  use Jido.Action,
    name: "light_turn_on",
    description: """
    Turn a light on. Returns whether the command was accepted, not whether \
    the light is lit.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. light:living_room"
      ]
    ]

  @behaviour Dobby.Tools

  @impl Dobby.Tools
  def label(arguments), do: "turning on the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do: Dobby.Tools.LightTurnOff.set_power(device_id, true)
end
