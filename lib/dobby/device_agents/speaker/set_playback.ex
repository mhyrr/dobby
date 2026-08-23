defmodule Dobby.DeviceAgents.Speaker.SetPlayback do
  @moduledoc """
  Accepts play or pause and emits the standard HA media-player call.

  Acceptance says only that the command left Dobby. The speaker's later state
  change says whether playback moved.
  """

  use Jido.Action,
    name: "speaker_set_playback",
    description: "Validates a speaker playback command and emits the HA call",
    schema: [
      playback: [type: {:in, [:play, :pause]}, required: true],
      ref: [type: :string, required: true]
    ]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{playback: playback, ref: ref}, context) do
    state = context.state

    if state.available and Map.get(state.capabilities, playback, false) do
      {:ok, %{last_command: %{ref: ref, action: playback, result: :accepted}},
       [
         %HACall{
           domain: "media_player",
           service: if(playback == :play, do: "media_play", else: "media_pause"),
           entity_id: state.entity_id,
           data: %{}
         }
       ]}
    else
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: playback,
           result: {:rejected, refusal(state, playback)}
         }
       }}
    end
  end

  defp refusal(%{available: available, name: name}, _playback) when available != true,
    do: "#{name} is unavailable"

  defp refusal(state, playback), do: "#{state.name} does not support #{playback}"
end
