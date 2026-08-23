defmodule Dobby.DeviceAgents.Speaker.SetVolume do
  @moduledoc """
  Validates a human volume percentage and emits HA's zero-to-one value.
  """

  use Jido.Action,
    name: "speaker_set_volume",
    description: "Validates speaker volume and emits the HA call",
    schema: [
      volume_percent: [type: :integer, required: true],
      ref: [type: :string, required: true]
    ]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{volume_percent: percent, ref: ref}, context) do
    state = context.state

    cond do
      not state.available ->
        reject(ref, :set_volume, "#{state.name} is unavailable")

      not Map.get(state.capabilities, :volume, false) ->
        reject(ref, :set_volume, "#{state.name} does not support volume control")

      percent < 0 or percent > 100 ->
        reject(ref, :set_volume, "volume must be between 0 and 100 percent")

      true ->
        {:ok,
         %{
           last_command: %{
             ref: ref,
             action: :set_volume,
             result: :accepted,
             volume_percent: percent
           }
         },
         [
           %HACall{
             domain: "media_player",
             service: "volume_set",
             entity_id: state.entity_id,
             data: %{volume_level: percent / 100}
           }
         ]}
    end
  end

  defp reject(ref, action, reason),
    do: {:ok, %{last_command: %{ref: ref, action: action, result: {:rejected, reason}}}}
end
