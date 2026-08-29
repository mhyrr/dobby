defmodule Dobby.Tools.SpeakerPause do
  @moduledoc "Tool: ask a household speaker to pause playback."

  use Jido.Action,
    name: "speaker_pause",
    description: "Pause a speaker. Returns command acceptance, not observed playback.",
    schema: [device: [type: :string, required: true, doc: "Speaker id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Speaker

  @impl Dobby.Tools
  def label(arguments), do: "pausing the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, context),
    do:
      Dobby.Tools.Device.command(
        device_id,
        Speaker,
        "speaker.set_playback",
        %{playback: :pause},
        context
      )
end
