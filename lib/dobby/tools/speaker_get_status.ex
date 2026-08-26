defmodule Dobby.Tools.SpeakerGetStatus do
  @moduledoc "Tool: read a household speaker from deterministic agent state."

  use Jido.Action,
    name: "speaker_get_status",
    description: "Read a speaker's playback, volume, mute, and current media state.",
    schema: [device: [type: :string, required: true, doc: "Speaker id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Speaker

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Speaker, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        playback: state.playback,
        volume_percent: state.volume_percent,
        muted: state.muted,
        media_title: state.media_title,
        capabilities: state.capabilities
      }
    end)
  end
end
