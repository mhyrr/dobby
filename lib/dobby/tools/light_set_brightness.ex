defmodule Dobby.Tools.LightSetBrightness do
  @moduledoc """
  Tool: set a light's brightness.

  Transport only. Whether this light dims at all is the agent's knowledge,
  discovered from Home Assistant — a refusal comes back with the reason and
  the model reports it, rather than the house pretending switches are
  dimmers.
  """

  use Jido.Action,
    name: "light_set_brightness",
    description: """
    Set a light's brightness as a percentage from 1 to 100. Also turns the \
    light on if it was off. Returns whether the command was accepted. Only \
    works on lights that support dimming.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. light:living_room"
      ],
      brightness_percent: [
        # `:integer` renders as `"integer"` in the JSON schema, which is the
        # truth; the coercion below is for models that send "60" or 60.0
        # anyway, because we have watched them do it.
        type: :integer,
        required: true,
        doc: "Brightness percentage, 1-100"
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Light

  @impl Dobby.Tools
  def label(arguments), do: "dimming the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def on_before_validate_params(params) do
    {:ok, Map.update(params, :brightness_percent, nil, &Dobby.Tools.to_percent/1)}
  end

  @impl true
  def run(%{device: device_id, brightness_percent: percent}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        Light,
        "light.set_brightness",
        %{brightness_percent: percent},
        context
      )
end
