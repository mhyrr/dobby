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
      state.available != true ->
        reject(ref, "#{state.name} is unavailable")

      state.supports_position != true ->
        reject(ref, "#{state.name} does not support position control")

      position < 0 or position > 100 ->
        reject(ref, "position must be between 0 and 100 percent")

      true ->
        {:ok,
         %{
           last_command: %{
             ref: ref,
             action: :set_position,
             result: :accepted,
             position: position,
             in_flight_until: Dobby.DeviceAgents.Shade.in_flight_until(),
             # Cleared by name: the deep merge into agent state would keep an
             # arrival the last command had not yet spent (`Move`).
             arrived: nil
           }
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
