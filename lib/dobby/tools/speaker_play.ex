defmodule Dobby.Tools.SpeakerPlay do
  @moduledoc "Tool: ask a household speaker to resume playback."

  use Jido.Action,
    name: "speaker_play",
    description: "Resume a speaker. Returns command acceptance, not observed playback.",
    schema: [device: [type: :string, required: true, doc: "Speaker id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Speaker

  @impl Dobby.Tools
  def label(arguments), do: "starting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do: Dobby.Tools.Device.command(device_id, Speaker, "speaker.set_playback", %{playback: :play})
end
