defmodule Dobby.DeviceAgents.Fan.SetSpeed do
  @moduledoc "Validates a fan speed percentage and emits HA's set_percentage call."

  use Jido.Action,
    name: "fan_set_speed",
    description: "Validates fan speed and emits the HA call",
    schema: [
      speed_percent: [type: :integer, required: true],
      ref: [type: :string, required: true]
    ]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{speed_percent: percent, ref: ref}, context) do
    state = context.state

    cond do
      state.available != true ->
        reject(ref, "#{state.name} is unavailable")

      state.supports_speed != true ->
        reject(ref, "#{state.name} does not support speed control")

      percent < 1 or percent > 100 ->
        reject(ref, "speed must be between 1 and 100 percent")

      true ->
        {:ok,
         %{
           last_command: %{
             ref: ref,
             action: :set_speed,
             result: :accepted,
             speed_percent: percent
           }
         },
         [
           %HACall{
             domain: "fan",
             service: "set_percentage",
             entity_id: state.entity_id,
             data: %{percentage: percent}
           }
         ]}
    end
  end

  defp reject(ref, reason),
    do: {:ok, %{last_command: %{ref: ref, action: :set_speed, result: {:rejected, reason}}}}
end
