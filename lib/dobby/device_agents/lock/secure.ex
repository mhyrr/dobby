defmodule Dobby.DeviceAgents.Lock.Secure do
  @moduledoc "Accepts a secure command and emits Home Assistant's lock service call."

  use Jido.Action,
    name: "lock_secure",
    description: "Validates a lock command and emits the HA call",
    schema: [ref: [type: :string, required: true]]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{ref: ref}, context) do
    state = context.state

    if state.available do
      {:ok, %{last_command: %{ref: ref, action: :secure, result: :accepted}},
       [%HACall{domain: "lock", service: "lock", entity_id: state.entity_id, data: %{}}]}
    else
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: :secure,
           result: {:rejected, "#{state.name} is unavailable"}
         }
       }}
    end
  end
end
