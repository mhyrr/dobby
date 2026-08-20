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
    with {:ok, _device, pid} <- Dobby.Home.resolve(device_id, Vacuum),
         {:ok, server_state} <- Jido.AgentServer.state(pid) do
      {:ok, status(server_state.agent.state)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp status(state) do
    %{
      device: state.dobby_id,
      name: state.name,
      available: state.available,
      activity: state.activity,
      battery_percent: state.battery_percent
    }
  end
end
