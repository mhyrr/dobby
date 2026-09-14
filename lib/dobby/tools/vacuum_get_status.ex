defmodule Dobby.Tools.VacuumGetStatus do
  @moduledoc """
  Tool: read a vacuum.

  Answered straight from device-agent state, with no Home Assistant round
  trip (design §6.2). The `device` argument is checked against the roster.
  """

  use Jido.Action,
    name: "vacuum_get_status",
    description: """
    Read a vacuum's current state: what it is doing (cleaning, docked, \
    paused, returning) and its battery percentage. Use the device id from \
    the roster.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. vacuum:roomba"
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Vacuum

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    Dobby.Tools.Device.status(device_id, Vacuum, fn state ->
      %{
        device: state.dobby_id,
        name: state.name,
        available: state.available,
        activity: state.activity,
        battery_percent: state.battery_percent
      }
    end)
  end
end
