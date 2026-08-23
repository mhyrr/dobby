defmodule Dobby.Tools.AccessCoverClose do
  @moduledoc "Tool: close a household access cover. Open is not part of Dobby's surface."

  use Jido.Action,
    name: "access_cover_close",
    description: "Close a garage door, gate, door, or window. Returns command acceptance.",
    schema: [device: [type: :string, required: true, doc: "Access-cover id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.AccessCover

  @impl Dobby.Tools
  def label(arguments), do: "closing the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do: Dobby.Tools.Device.command(device_id, AccessCover, "access_cover.close")
end
