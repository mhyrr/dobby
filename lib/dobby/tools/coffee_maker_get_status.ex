defmodule Dobby.Tools.CoffeeMakerGetStatus do
  @moduledoc "Reads appliance observations through the same roster boundary as every device tool."

  use Jido.Action,
    name: "coffee_maker_get_status",
    description:
      "Reports coffee maker activity, supplies, cleaning, and remote readiness. Read-only; null means unknown. Remote readiness is not permission to brew.",
    schema: [device: [type: :string, required: true, doc: "Device id from the roster."]]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.CoffeeMaker

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, CoffeeMaker, fn state ->
      CoffeeMaker.snapshot(state)
      |> Map.delete(:id)
      |> Map.put(:device, state.dobby_id)
    end)
  end
end
