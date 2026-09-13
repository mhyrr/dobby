defmodule Dobby.Tools.DryerGetStatus do
  @moduledoc "Reads appliance observations through the same roster boundary as every device tool."

  use Jido.Action,
    name: "dryer_get_status",
    description:
      "Reports the dryer cycle, door, and remote readiness. Read-only; null means unknown. Remaining time includes its reported unit; do not infer completion from zero remaining time." <>
        " finish_at is on the household's local clock.",
    schema: [device: [type: :string, required: true, doc: "Device id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Dryer

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Dryer, fn state ->
      Dryer.snapshot(state)
      |> Map.delete(:id)
      |> Map.put(:device, state.dobby_id)
    end)
  end
end
