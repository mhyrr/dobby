defmodule Dobby.Tools.WineCoolerGetStatus do
  @moduledoc "Reads appliance observations through the same roster boundary as every device tool."

  use Jido.Action,
    name: "wine_cooler_get_status",
    description:
      "Reports measured wine cooler temperatures, separate targets, and door state. Read-only; null means unknown. Targets never stand in for measured temperatures; units accompany each temperature.",
    schema: [device: [type: :string, required: true, doc: "Device id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.WineCooler

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, WineCooler, fn state ->
      WineCooler.snapshot(state)
      |> Map.delete(:id)
      |> Map.put(:device, state.dobby_id)
    end)
  end
end
