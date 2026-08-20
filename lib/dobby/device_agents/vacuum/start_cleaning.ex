defmodule Dobby.DeviceAgents.Vacuum.StartCleaning do
  @moduledoc """
  Decides whether the vacuum may start, and if so describes the HA call.

  No side effect here, as with every device action: validate, then return a
  `Dobby.Directive.HACall`. Agent state does not change on acceptance — the
  robot actually leaving its dock arrives later as a state change, or does
  not.
  """

  use Jido.Action,
    name: "vacuum_start_cleaning",
    description: "Validates starting a vacuum and emits the Home Assistant call",
    schema: [
      ref: [type: :string, required: true]
    ]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{ref: ref}, context) do
    state = context.state

    if state.available do
      {:ok, %{last_command: %{ref: ref, action: :start_cleaning, result: :accepted}},
       [%HACall{domain: "vacuum", service: "start", entity_id: state.entity_id, data: %{}}]}
    else
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: :start_cleaning,
           result: {:rejected, "#{state.name} is unavailable"}
         }
       }}
    end
  end
end
