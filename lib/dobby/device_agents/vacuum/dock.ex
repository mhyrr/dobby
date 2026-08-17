defmodule Dobby.DeviceAgents.Vacuum.Dock do
  @moduledoc """
  Decides whether the vacuum may be sent home, and if so describes the HA
  call. Docking an already-docked robot is accepted rather than refused —
  "go home" is a safe wish whatever the robot is doing, and HA treats it as
  the no-op it is.
  """

  use Jido.Action,
    name: "vacuum_dock",
    description: "Validates sending a vacuum home and emits the Home Assistant call",
    schema: [
      ref: [type: :string, required: true]
    ]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{ref: ref}, context) do
    state = context.state

    if state.available do
      {:ok, %{last_command: %{ref: ref, action: :dock, result: :accepted}},
       [
         %HACall{
           domain: "vacuum",
           service: "return_to_base",
           entity_id: state.entity_id,
           data: %{}
         }
       ]}
    else
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: :dock,
           result: {:rejected, "#{state.name} is unavailable"}
         }
       }}
    end
  end
end
