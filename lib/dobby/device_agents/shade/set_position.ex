defmodule Dobby.DeviceAgents.Shade.SetPosition do
  @moduledoc "Validates a shade position and emits HA's set_cover_position call."

  use Jido.Action,
    name: "shade_set_position",
    description: "Validates a shade position and emits the HA call",
    schema: [position: [type: :integer, required: true], ref: [type: :string, required: true]]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{position: position, ref: ref}, context) do
    state = context.state

    cond do
      not state.available ->
        reject(ref, "#{state.name} is unavailable")

      not state.supports_position ->
        reject(ref, "#{state.name} does not support position control")

      position < 0 or position > 100 ->
        reject(ref, "position must be between 0 and 100 percent")

      true ->
        {:ok,
         %{
           last_command: %{ref: ref, action: :set_position, result: :accepted, position: position}
         },
         [
           %HACall{
             domain: "cover",
             service: "set_cover_position",
             entity_id: state.entity_id,
             data: %{position: position}
           }
         ]}
    end
  end

  defp reject(ref, reason),
    do: {:ok, %{last_command: %{ref: ref, action: :set_position, result: {:rejected, reason}}}}
end
