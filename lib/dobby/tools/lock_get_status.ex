defmodule Dobby.Tools.LockGetStatus do
  @moduledoc "Tool: read a household lock from deterministic agent state."

  use Jido.Action,
    name: "lock_get_status",
    description: "Read whether a household lock is secured, open, moving, or jammed.",
    schema: [device: [type: :string, required: true, doc: "Lock id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Lock

  @impl Dobby.Tools
  def label(arguments), do: "checking the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Lock, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        lock_state: state.lock_state
      }
    end)
  end
end
