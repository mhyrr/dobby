defmodule Dobby.Tools.LockSecure do
  @moduledoc "Tool: secure a household lock. Unlock is not part of Dobby's surface."

  use Jido.Action,
    name: "lock_secure",
    description: "Secure a household lock. Returns command acceptance, not observed state.",
    schema: [device: [type: :string, required: true, doc: "Lock id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Lock

  @impl Dobby.Tools
  def label(arguments), do: "securing the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do: Dobby.Tools.Device.command(device_id, Lock, "lock.secure", %{}, %{lock_state: :locked})
end
