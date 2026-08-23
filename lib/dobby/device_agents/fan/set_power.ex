defmodule Dobby.DeviceAgents.Fan.SetPower do
  @moduledoc "Accepts fan power and emits Home Assistant's fan service call."

  use Jido.Action,
    name: "fan_set_power",
    description: "Validates fan power and emits the HA call",
    schema: [
      power: [type: {:in, [:on, :off]}, required: true],
      ref: [type: :string, required: true]
    ]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{power: power, ref: ref}, context) do
    state = context.state

    if state.available do
      {:ok, %{last_command: %{ref: ref, action: :set_power, result: :accepted, power: power}},
       [%HACall{domain: "fan", service: "turn_#{power}", entity_id: state.entity_id, data: %{}}]}
    else
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: :set_power,
           result: {:rejected, "#{state.name} is unavailable"}
         }
       }}
    end
  end
end
