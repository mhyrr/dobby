defmodule Dobby.Tools.LightGetStatus do
  @moduledoc """
  Tool: read a light.

  Answered straight from device-agent state, with no Home Assistant round
  trip (design §6.2). The `device` argument is checked against the roster, so
  the model cannot read a light this house does not have.
  """

  use Jido.Action,
    name: "light_get_status",
    description: """
    Read a light's current state: on or off, and its brightness percentage \
    if it dims. Use the device id from the roster.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. light:living_room"
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Light

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Light, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        power: state.power,
        brightness_percent: state.brightness_percent,
        dimmable: Light.dimmable?(state)
      }
    end)
  end
end
