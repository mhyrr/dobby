defmodule Dobby.Tools.LightTurnOff do
  @moduledoc """
  Tool: turn a light off.

  Transport only, and also home of the shared `set_power/2` carrier both
  switch tools ride: on and off are one decision in the agent
  (`Light.SetPower`), so they are one code path here — split into two tools
  only because two names leave the model nothing to encode in arguments.
  """

  use Jido.Action,
    name: "light_turn_off",
    description: """
    Turn a light off. Returns whether the command was accepted.
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
  def label(arguments), do: "turning off the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context), do: set_power(device_id, false, context)

  @doc false
  def set_power(device_id, on, context),
    do: Dobby.Tools.Device.command(device_id, Light, "light.set_power", %{on: on}, context)
end
