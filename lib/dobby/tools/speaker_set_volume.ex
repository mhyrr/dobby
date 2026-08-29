defmodule Dobby.Tools.SpeakerSetVolume do
  @moduledoc "Tool: set a household speaker's volume."

  use Jido.Action,
    name: "speaker_set_volume",
    description: "Set speaker volume from 0 to 100 percent. Returns command acceptance.",
    schema: [
      device: [type: :string, required: true, doc: "Speaker id from the roster."],
      volume_percent: [type: :integer, required: true, doc: "Volume from 0 to 100 percent."]
    ]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Speaker

  @impl Dobby.Tools
  def label(arguments), do: "setting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def on_before_validate_params(params),
    do: {:ok, Map.update(params, :volume_percent, nil, &Dobby.Tools.to_percent/1)}

  @impl true
  def run(%{device: device_id, volume_percent: percent}, context) do
    Dobby.Tools.Device.command(
      device_id,
      Speaker,
      "speaker.set_volume",
      %{
        volume_percent: percent
      },
      context
    )
  end
end
