defmodule Dobby.DeviceAgents.Shade.Move do
  @moduledoc "Accepts open or close and emits Home Assistant's cover service call."

  use Jido.Action,
    name: "shade_move",
    description: "Validates a shade movement and emits the HA call",
    schema: [
      movement: [type: {:in, [:open, :close]}, required: true],
      ref: [type: :string, required: true]
    ]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{movement: movement, ref: ref}, context) do
    state = context.state

    if state.available do
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: movement,
           result: :accepted,
           in_flight_until: Dobby.DeviceAgents.Shade.in_flight_until(),
           # Named so the deep merge into agent state clears what the last
           # command left: an earlier position, or an arrival not yet spent.
           position: nil,
           arrived: nil
         }
       },
       [
         %HACall{
           domain: "cover",
           service: "#{movement}_cover",
           entity_id: state.entity_id,
           data: %{}
         }
       ]}
    else
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: movement,
           result: {:rejected, "#{state.name} is unavailable"}
         }
       }}
    end
  end
end
