defmodule Dobby.DeviceAgents.AccessCover.Close do
  @moduledoc "Accepts a close command and emits Home Assistant's cover service call."

  use Jido.Action,
    name: "access_cover_close",
    description: "Validates an access-cover close command and emits the HA call",
    schema: [ref: [type: :string, required: true]]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{ref: ref}, context) do
    state = context.state

    if state.available do
      {:ok, %{last_command: %{ref: ref, action: :close, result: :accepted}},
       [%HACall{domain: "cover", service: "close_cover", entity_id: state.entity_id, data: %{}}]}
    else
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: :close,
           result: {:rejected, "#{state.name} is unavailable"}
         }
       }}
    end
  end
end
