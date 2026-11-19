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
      {:ok, %{last_command: accepted(ref, state.lock_state)},
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

  # A door that is already locked never echoes: Home Assistant sends no state
  # change when nothing changed. The echo is one-shot and is consumed only when
  # it lands (`SyncState`), so a command waiting for one that never comes
  # would stand, and the next hand to lock the door would be read as this
  # command's echo. The nightly "lock the doors" fires on locked doors most
  # nights. So the command is accepted already consumed: the outcome still
  # reads back and the call still goes out, but nothing waits for an echo. The
  # witness already treats it as answered, from the same snapshot.
  defp accepted(ref, :locked),
    do: %{ref: ref, action: :secure, result: :accepted, echoed: true}

  defp accepted(ref, _lock_state), do: %{ref: ref, action: :secure, result: :accepted}
end
